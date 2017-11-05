
# Linux kernel的中断子系统

蜗窝 http://www.wowotech.net/

## (一)：综述

### 一、前言

一个合格的linux驱动工程师需要对kernel中的中断子系统有深刻的理解，只有这样，在写具体driver的时候才能：

1、正确的使用linux kernel提供的的API，例如最著名的request_threaded_irq(request_irq)接口；

2、正确使用同步机制保护驱动代码中的临界区；

3、正确的使用kernel提供的softirq、tasklet、workqueue等机制来完成具体的中断处理；

基于上面的原因，我希望能够通过一系列的文档来描述清楚linux kernel中的中断子系统方方面面的知识。一方面是整理自己的思绪，另外一方面，希望能够对其他的驱动工程师(或者想从事linux驱动工作的工程师)有所帮助。

### 二、中断系统相关硬件描述

中断硬件系统主要有三种器件参与，各个外设、中断控制器和CPU。

各个外设提供irq request line，在发生中断事件的时候，通过irq request line上的电气信号向CPU系统请求处理。外设的irq request line太多，CPU需要一个小伙伴帮他，这就是Interrupt controller。

Interrupt Controller是连接外设中断系统和CPU系统的桥梁。根据外设irq request line的多少，Interrupt Controller可以级联。

CPU的主要功能是运算，因此CPU并不处理中断优先级，那是Interrupt controller的事情。对于CPU而言，一般有两种中断请求，例如：对于ARM，是IRQ和FIQ信号线，分别让ARM进入IRQ mode和FIQ mode。对于X86，有可屏蔽中断和不可屏蔽中断。

本章节不是描述具体的硬件，而是使用了HW block这样的概念。例如CPU HW block是只ARM core或者X86这样的实际硬件block的一个逻辑描述，实际中，可能是任何可能的CPU block。

#### 1、HW中断系统的逻辑block图

我对HW中断系统之逻辑block diagram的理解如下图所示：

![](attachment\1.1.gif)

系统中有若干个CPU block用来接收中断事件并进行处理，若干个Interrupt controller形成树状的结构，汇集系统中所有外设的irq request line，并将中断事件分发给某一个CPU block进行处理。

从接口层面看，主要有两类接口，一种是中断接口。有的实现中，具体中断接口的形态就是一个硬件的信号线，通过电平信号传递中断事件(ARM以及GIC组成的中断系统就是这么设计的)。

有些系统采用了其他的方法来传递中断事件，比如x86+APIC(Advanced Programmable Interrupt Controller)组成的系统，每个x86的核有一个Local APIC，这些Local APIC们通过ICC(Interrupt Controller Communication)bus连接到IO APIC上。IO APIC收集各个外设的中断，并翻译成总线上的message，传递给某个CPU上的Local APIC。因此，上面的红色线条也是逻辑层面的中断信号，可能是实际的PCB上的铜线(或者SOC内部的铜线)，也可能是一个message而已。

除了中断接口，CPU和Interrupt Controller之间还需要有控制信息的交流。Interrupt Controller会开放一些寄存器让CPU访问、控制。

#### 2、多个Interrupt controller和多个cpu之间的拓扑结构

Interrupt controller有的是支持多个CPU core的(例如GIC、APIC等)，有的不支持(例如S3C2410的中断控制器，X86平台的PIC等)。如果硬件平台中只有一个GIC的话，那么通过控制该GIC的寄存器可以将所有的外设中断，分发给连接在该interrupt controller上的CPU。如果有多个GIC呢(或者级联的interrupt controller都支持multi cpu core)?假设我们要设计一个非常复杂的系统，系统中有8个CPU，有2000个外设中断要处理，这时候你如何设计系统中的interrupt controller?如果使用GIC的话，我们需要两个GIC(一个GIC最多支持1024个中断源)，一个是root GIC，另外一个是secondary GIC。这时候，你有两种方案：

(1) 把8个cpu都连接到root GIC上，secondary GIC不接CPU。这时候原本挂接在secondary GIC的外设中断会输出到某个cpu，现在，只能是(通过某个cpu interface的irq signal)输到root GIC的某个SPI上。对于软件而言，这是一个比较简单的设计，secondary GIC的cpu interface的设定是固定不变的，永远是从一个固定的CPU interface输出到root GIC。这种方案的坏处是：这时候secondary GIC的PPI和SGI都是没有用的了。此外，在这种设定下，所有连接在secondary GIC上的外设中断要送达的target CPU是统一处理的，要么送去cpu0，要么cpu 5，不能单独控制。

(2) 当然，你也可以让每个GIC分别连接4个CPU core，root GIC连接CPU0~CPU3，secondary GIC连接CPU4~CPU7。这种状态下，连接在root GIC的中断可以由CPU0~CPU3分担处理，连接在secondary GIC的中断可以由CPU4~CPU7分担处理。但这样，在中断处理方面看起来就体现不出8核的威力了。

注：上一节中的逻辑block示意图采用的就是方案一。

#### 3、Interrupt controller把中断事件送给哪个CPU?

毫无疑问，只有支持multi cpu core的中断控制器才有这种幸福的烦恼。一般而言，中断控制器可以把中断事件上报给一个CPU或者一组CPU(包括广播到所有的CPU上去)。对于外设类型的中断，当然是送到一个cpu上就OK了，我看不出来要把这样的中断送给多个CPU进行处理的必要性。如果送达了多个cpu，实际上，也应该只有一个handler实际和外设进行交互，另外一个cpu上的handler的动作应该是这样的：发现该irq number对应的中断已经被另外一个cpu处理了，直接退出handler，返回中断现场。IPI的中断不存在这个限制，IPI更像一个CPU之间通信的机制，对这种中断广播应该是毫无压力。

实际上，从用户的角度看，其需求是相当复杂的，我们的目标可能包括：

(1) 让某个IRQ number的中断由某个特定的CPU处理

(2) 让某个特定的中断由几个CPU轮流处理

……

当然，具体的需求可能更加复杂，但是如何区分软件和硬件的分工呢?让硬件处理那么复杂的策略其实是不合理的，复杂的逻辑如果由硬件实现，那么就意味着更多的晶体管，更多的功耗。因此，最普通的做法就是为Interrupt Controller支持的每一个中断设定一个target cpu的控制接口(当然应该是以寄存器形式出现，对于GIC，这个寄存器就是Interrupt processor target register)。系统有多个cpu，这个控制接口就有多少个bit，每个bit代表一个CPU。如果该bit设定为1，那么该interrupt就上报给该CPU，如果为0，则不上报给该CPU。这样的硬件逻辑比较简单，剩余的控制内容就交给软件好了。例如如果系统有两个cpu core，某中断想轮流由两个CPU处理。那么当CPU0相应该中断进入interrupt handler的时候，可以将Interrupt processor target register中本CPU对应的bit设定为0，另外一个CPU的bit设定为1。这样，在下次中断发生的时候，interupt controller就把中断送给了CPU1。对于CPU1而言，在执行该中断的handler的时候，将Interrupt processor target register中CPU0的bit为设置为1，disable本CPU的比特位，这样在下次中断发生的时候，interupt controller就把中断送给了CPU0。这样软件控制的结果就是实现了特定中断由2个CPU轮流处理的算法。

#### 4、更多的思考

面对这个HW中断系统之逻辑block diagram，我们其实可以提出更多的问题：

(1) 中断控制器发送给CPU的中断是否可以收回?重新分发给另外一个CPU?

(2) 系统中的中断如何分发才能获得更好的性能呢?

(3) 中断分发的策略需要考虑哪些因素呢?

……

很多问题其实我也没有答案，慢慢思考，慢慢逼近真相吧。

### 二、中断子系统相关的软件框架

linux kernel的中断子系统相关的软件框架图如下所示：

![](attachment\1.2.gif)

由上面的block图，我们可知linux kernel的中断子系统分成4个部分：

(1) 硬件无关的代码，我们称之Linux kernel通用中断处理模块。无论是哪种CPU，哪种controller，其中断处理的过程都有一些相同的内容，这些相同的内容被抽象出来，和HW无关。此外，各个外设的驱动代码中，也希望能用一个统一的接口实现irq相关的管理(不和具体的中断硬件系统以及CPU体系结构相关)这些“通用”的代码组成了linux kernel interrupt subsystem的核心部分。

(2) CPU architecture相关的中断处理。 和系统使用的具体的CPU architecture相关。

(3) Interrupt controller驱动代码 。和系统使用的Interrupt controller相关。

(4) 普通外设的驱动。这些驱动将使用Linux kernel通用中断处理模块的API来实现自己的驱动逻辑。

### 三、中断子系统文档规划

中断相关的文档规划如下：

1、linux kernel的中断子系统之(一)，也就是本文，其实是一个导论，没有实际的内容，主要是给读者一个大概的软硬件框架。

http://www.wowotech.net/irq_subsystem/interrupt_subsystem_architecture.html/comment-page-2

2、linux kernel的中断子系统之(二)：irq domain介绍。主要描述如何将一个HW interrupt ID转换成IRQ number。

http://www.wowotech.net/linux_kenrel/irq-domain.html

3、linux kernel的中断子系统之(三)：IRQ number和中断描述符。主要描述中断描述符相关的数据结构和接口API。

http://www.wowotech.net/linux_kenrel/interrupt_descriptor.html

4、linux kernel的中断子系统之(四)：high level irq event handler。

http://www.wowotech.net/linux_kenrel/High_level_irq_event_handler.html

5、linux kernel的中断子系统之(五)：driver API。主要以一个普通的驱动程序为视角，看待linux interrupt subsystem提供的API，如何利用这些API，分配资源，是否资源，如何处理中断相关的同步问题等等。

http://www.wowotech.net/linux_kenrel/request_threaded_irq.html

6、linux kernel的中断子系统之(六)：ARM中断处理过程，这份文档以ARM CPU为例，描述ARM相关的中断处理过程

http://www.wowotech.net/linux_kenrel/irq_handler.html

7、linux kernel的中断子系统之(七)：GIC代码分析，这份文档是以一个具体的interrupt controller为例，描述irq chip driver的代码构成情况。

http://www.wowotech.net/linux_kenrel/gic_driver.html

8、linux kernel的中断子系统之(八)：softirq

http://www.wowotech.net/linux_kenrel/soft-irq.html

9、linux kernel的中断子系统之(九)：tasklet

http://www.wowotech.net/irq_subsystem/tasklet.html

## (二)：IRQ Domain介绍

### 一、概述

在linux kernel中，我们使用下面两个ID来标识一个来自外设的中断：

1、IRQ number。CPU需要为每一个外设中断编号，我们称之IRQ Number。这个IRQ number是一个虚拟的interrupt ID，和硬件无关，仅仅是被CPU用来标识一个外设中断。

2、HW interrupt ID。对于interrupt controller而言，它收集了多个外设的interrupt request line并向上传递，因此，interrupt controller需要对外设中断进行编码。Interrupt controller用HW interrupt ID来标识外设的中断。在interrupt controller级联的情况下，仅仅用HW interrupt ID已经不能唯一标识一个外设中断，还需要知道该HW interrupt ID所属的interrupt controller(HW interrupt ID在不同的Interrupt controller上是会重复编码的)。

这样，CPU和interrupt controller在标识中断上就有了一些不同的概念，但是，对于驱动工程师而言，我们和CPU视角是一样的，我们只希望得到一个IRQ number，而不关心具体是那个interrupt controller上的那个HW interrupt ID。这样一个好处是在中断相关的硬件发生变化的时候，驱动软件不需要修改。因此，linux kernel中的中断子系统需要提供一个将HW interrupt ID映射到IRQ number上来的机制，这就是本文主要的内容。

### 二、历史

关于HW interrupt ID映射到IRQ number上这事，在过去系统只有一个interrupt controller的时候还是很简单的，中断控制器上实际的HW interrupt line的编号可以直接变成IRQ number。例如我们大家都熟悉的SOC内嵌的interrupt controller，这种controller多半有中断状态寄存器，这个寄存器可能有64个bit(也可能更多)，每个bit就是一个IRQ number，可以直接进行映射。这时候，GPIO的中断在中断控制器的状态寄存器中只有一个bit，因此所有的GPIO中断只有一个IRQ number，在该通用GPIO中断的irq handler中进行deduplex，将各个具体的GPIO中断映射到其相应的IRQ number上。如果你是一个足够老的工程师，应该是经历过这个阶段的。

随着linux kernel的发展，将interrupt controller抽象成irqchip这个概念越来越流行，甚至GPIO controller也可以被看出一个interrupt controller chip，这样，系统中至少有两个中断控制器了，一个传统意义的中断控制器，一个是GPIO controller type的中断控制器。随着系统复杂度加大，外设中断数据增加，实际上系统可以需要多个中断控制器进行级联，面对这样的趋势，linux kernel工程师如何应对?答案就是irq domain这个概念。

我们听说过很多的domain，power domain，clock domain等等，所谓domain，就是领域，范围的意思，也就是说，任何的定义出了这个范围就没有意义了。系统中所有的interrupt controller会形成树状结构，对于每个interrupt controller都可以连接若干个外设的中断请求(我们称之interrupt source)，interrupt controller会对连接其上的interrupt source(根据其在Interrupt controller中物理特性)进行编号(也就是HW interrupt ID了)。但这个编号仅仅限制在本interrupt controller范围内。

### 三、接口

#### 1、向系统注册irq domain

具体如何进行映射是interrupt controller自己的事情，不过，有软件架构思想的工程师更愿意对形形色色的interrupt controller进行抽象，对如何进行HW interrupt ID到IRQ number映射关系上进行进一步的抽象。因此，通用中断处理模块中有一个irq domain的子模块，该模块将这种映射关系分成了三类：

(1) 线性映射。其实就是一个lookup table，HW interrupt ID作为index，通过查表可以获取对应的IRQ number。对于Linear map而言，interrupt controller对其HW interrupt ID进行编码的时候要满足一定的条件：hw ID不能过大，而且ID排列最好是紧密的。对于线性映射，其接口API如下：

```c
static inline struct irq_domain *irq_domain_add_linear(struct device_node *of_node,
    unsigned int size,－－－－－－－－－该interrupt domain支持多少IRQ
    const struct irq_domain_ops *ops,－－－callback函数
    void *host_data)－－－－－driver私有数据
{
    return __irq_domain_add(of_node, size, size, 0, ops, host_data);
}
```

(2) Radix Tree map。建立一个Radix Tree来维护HW interrupt ID到IRQ number映射关系。HW interrupt ID作为lookup key，在Radix Tree检索到IRQ number。如果的确不能满足线性映射的条件，可以考虑Radix Tree map。实际上，内核中使用Radix Tree map的只有powerPC和MIPS的硬件平台。对于Radix Tree map，其接口API如下：

```c
static inline struct irq_domain *irq_domain_add_tree(struct device_node *of_node,
   const struct irq_domain_ops *ops,
   void *host_data)
{
    return __irq_domain_add(of_node, 0, ~0, 0, ops, host_data);
}
```

(3) no map。有些中断控制器很强，可以通过寄存器配置HW interrupt ID而不是由物理连接决定的。例如PowerPC 系统使用的MPIC (Multi-Processor Interrupt Controller)。在这种情况下，不需要进行映射，我们直接把IRQ number写入HW interrupt ID配置寄存器就OK了，这时候，生成的HW interrupt ID就是IRQ number，也就不需要进行mapping了。对于这种类型的映射，其接口API如下：

```c
static inline struct irq_domain *irq_domain_add_nomap(struct device_node *of_node,
    unsigned int max_irq,
    const struct irq_domain_ops *ops,
    void *host_data)
{
    return __irq_domain_add(of_node, 0, max_irq, max_irq, ops, host_data);
}
```

这类接口的逻辑很简单，根据自己的映射类型，初始化struct irq_domain中的各个成员，调用__irq_domain_add将该irq domain挂入irq_domain_list的全局列表。

#### 2、为irq domain创建映射

上节的内容主要是向系统注册一个irq domain，具体HW interrupt ID和IRQ number的映射关系都是空的，因此，具体各个irq domain如何管理映射所需要的database还是需要建立的。例如：对于线性映射的irq domain，我们需要建立线性映射的lookup table，对于Radix Tree map，我们要把那个反应IRQ number和HW interrupt ID的Radix tree建立起来。创建映射有四个接口函数：

(1) 调用irq_create_mapping函数建立HW interrupt ID和IRQ number的映射关系。该接口函数以irq domain和HW interrupt ID为参数，返回IRQ number(这个IRQ number是动态分配的)。该函数的原型定义如下：

```c
extern unsigned int irq_create_mapping(struct irq_domain *host, irq_hw_number_t hwirq);
```

驱动调用该函数的时候必须提供HW interrupt ID，也就是意味着driver知道自己使用的HW interrupt ID，而一般情况下，HW interrupt ID其实对具体的driver应该是不可见的，不过有些场景比较特殊，例如GPIO类型的中断，它的HW interrupt ID和GPIO有着特定的关系，driver知道自己使用那个GPIO，也就是知道使用哪一个HW interrupt ID了。


(2) irq_create_strict_mappings。这个接口函数用来为一组HW interrupt ID建立映射。具体函数的原型定义如下：

```c
extern int irq_create_strict_mappings(struct irq_domain *domain,
    unsigned int irq_base,
    irq_hw_number_t hwirq_base, int count);
```

(3) irq_create_of_mapping。看到函数名字中的of(open firmware)，我想你也可以猜到了几分，这个接口当然是利用device tree进行映射关系的建立。具体函数的原型定义如下：

```c
extern unsigned int irq_create_of_mapping(struct of_phandle_args *irq_data);
```

通常，一个普通设备的device tree node已经描述了足够的中断信息，在这种情况下，该设备的驱动在初始化的时候可以调用irq_of_parse_and_map这个接口函数进行该device node中和中断相关的内容(interrupts和interrupt-parent属性)进行分析，并建立映射关系，具体代码如下：

```c
unsigned int irq_of_parse_and_map(struct device_node *dev, int index)
{
    struct of_phandle_args oirq;
    if (of_irq_parse_one(dev, index, &oirq))－－－－分析device node中的interrupt相关属性
    return 0;
    return irq_create_of_mapping(&oirq);－－－－－创建映射，并返回对应的IRQ number
}
```

对于一个使用Device tree的普通驱动程序(我们推荐这样做)，基本上初始化需要调用irq_of_parse_and_map获取IRQ number，然后调用request_threaded_irq申请中断handler。

(4) irq_create_direct_mapping。这是给no map那种类型的interrupt controller使用的，这里不再赘述。

### 四、数据结构描述

#### 1、irq domain的callback接口

```c
struct irq_domain_ops抽象了一个irq domain的callback函数，定义如下：
struct irq_domain_ops {
    int (*match)(struct irq_domain *d, struct device_node *node);
    int (*map)(struct irq_domain *d, unsigned int virq, irq_hw_number_t hw);
    void (*unmap)(struct irq_domain *d, unsigned int virq);
    int (*xlate)(struct irq_domain *d, struct device_node *node,
    const u32 *intspec, unsigned int intsize,
    unsigned long *out_hwirq, unsigned int *out_type);
};
```

我们先看xlate函数，语义是翻译(translate)的意思，那么到底翻译什么呢?在DTS文件中，各个使用中断的device node会通过一些属性(例如interrupts和interrupt-parent属性)来提供中断信息给kernel以便kernel可以正确的进行driver的初始化动作。这里，interrupts属性所表示的interrupt specifier只能由具体的interrupt controller(也就是irq domain)来解析。而xlate函数就是将指定的设备(node参数)上若干个(intsize参数)中断属性(intspec参数)翻译成HW interrupt ID(out_hwirq参数)和trigger类型(out_type)。

match是判断一个指定的interrupt controller(node参数)是否和一个irq domain匹配(d参数)，如果匹配的话，返回1。实际上，内核中很少定义这个callback函数，实际上struct irq_domain中有一个of_node指向了对应的interrupt controller的device node，因此，如果不提供该函数，那么default的匹配函数其实就是判断irq domain的of_node成员是否等于传入的node参数。

map和unmap是操作相反的函数，我们描述其中之一就OK了。调用map函数的时机是在创建(或者更新)HW interrupt ID(hw参数)和IRQ number(virq参数)关系的时候。其实，从发生一个中断到调用该中断的handler仅仅调用一个request_threaded_irq是不够的，还需要针对该irq number设定：

(1) 设定该IRQ number对应的中断描述符(struct irq_desc)的irq chip

(2) 设定该IRQ number对应的中断描述符的highlevel irq-events handler

(3) 设定该IRQ number对应的中断描述符的 irq chip data

这些设定不适合由具体的硬件驱动来设定，因此在Interrupt controller，也就是irq domain的callback函数中设定。

#### 2、irq domain

在内核中，irq domain的概念由struct irq_domain表示：

```c
struct irq_domain {
    struct list_head link;
    const char *name;
    const struct irq_domain_ops *ops; －－－－callback函数
    void *host_data;
    /* Optional data */
    struct device_node *of_node; －－－－该interrupt domain对应的interrupt controller的device node
    struct irq_domain_chip_generic *gc; －－－generic irq chip的概念，本文暂不描述
    /* reverse map data. The linear map gets appended to the irq_domain */
    irq_hw_number_t hwirq_max; －－－－该domain中最大的那个HW interrupt ID
    unsigned int revmap_direct_max_irq; －－－－
    unsigned int revmap_size; －－－线性映射的size，for Radix Tree map和no map，该值等于0
    struct radix_tree_root revmap_tree; －－－－Radix Tree map使用到的radix tree root node
    unsigned int linear_revmap[]; －－－－－线性映射使用的lookup table
};
```

linux内核中，所有的irq domain被挂入一个全局链表，链表头定义如下：

```c
static LIST_HEAD(irq_domain_list);
```

struct irq_domain中的link成员就是挂入这个队列的节点。通过irq_domain_list这个指针，可以获取整个系统中HW interrupt ID和IRQ number的mapping DB。host_data定义了底层interrupt controller使用的私有数据，和具体的interrupt controller相关(对于GIC，该指针指向一个struct gic_chip_data数据结构)。

对于线性映射：

(1) linear_revmap保存了一个线性的lookup table，index是HW interrupt ID，table中保存了IRQ number值

(2) revmap_size等于线性的lookup table的size。

(3) hwirq_max保存了最大的HW interrupt ID

(4) revmap_direct_max_irq没有用，设定为0。revmap_tree没有用。

对于Radix Tree map：

(1) linear_revmap没有用，revmap_size等于0。

(2) hwirq_max没有用，设定为一个最大值。

(3) revmap_direct_max_irq没有用，设定为0。

(4) revmap_tree指向Radix tree的root node。

### 五、中断相关的Device Tree知识回顾

想要进行映射，首先要了解interrupt controller的拓扑结构。系统中的interrupt controller的拓扑结构以及其interrupt request line的分配情况(分配给哪一个具体的外设)都在Device Tree Source文件中通过下面的属性给出了描述。这些内容在Device Tree的三份文档中给出了一些描述，这里简单总结一下：

对于那些产生中断的外设，我们需要定义interrupt-parent和interrupts属性：

(1) interrupt-parent。表明该外设的interrupt request line物理的连接到了哪一个中断控制器上

(2) interrupts。这个属性描述了具体该外设产生的interrupt的细节信息(也就是传说中的interrupt specifier)。例如：HW interrupt ID(由该外设的device node中的interrupt-parent指向的interrupt controller解析)、interrupt触发类型等。

对于Interrupt controller，我们需要定义interrupt-controller和#interrupt-cells的属性：

(1) interrupt-controller。表明该device node就是一个中断控制器

(2) #interrupt-cells。该中断控制器用多少个cell(一个cell就是一个32-bit的单元)描述一个外设的interrupt request line。?具体每个cell表示什么样的含义由interrupt controller自己定义。

(3) interrupts和interrupt-parent。对于那些不是root 的interrupt controller，其本身也是作为一个产生中断的外设连接到其他的interrupt controller上，因此也需要定义interrupts和interrupt-parent的属性。

### 六、Mapping DB的建立

#### 1、概述

系统中HW interrupt ID和IRQ number的mapping DB是在整个系统初始化的过程中建立起来的，过程如下：

(1) DTS文件描述了系统中的interrupt controller以及外设IRQ的拓扑结构，在linux kernel启动的时候，由bootloader传递给kernel(实际传递的是DTB)。

(2) 在Device Tree初始化的时候，形成了系统内所有的device node的树状结构，当然其中包括所有和中断拓扑相关的数据结构(所有的interrupt controller的node和使用中断的外设node)

(3) 在machine driver初始化的时候会调用of_irq_init函数，在该函数中会扫描所有interrupt controller的节点，并调用适合的interrupt controller driver进行初始化。毫无疑问，初始化需要注意顺序，首先初始化root，然后first level，second level，最好是leaf node。在初始化的过程中，一般会调用上节中的接口函数向系统增加irq domain。有些interrupt controller会在其driver初始化的过程中创建映射

(4) 在各个driver初始化的过程中，创建映射

#### 2、 interrupt controller初始化的过程中，注册irq domain

我们以GIC的代码为例。具体代码在gic_of_init->gic_init_bases中，如下：

```c
void __init gic_init_bases(unsigned int gic_nr, int irq_start,
void __iomem *dist_base, void __iomem *cpu_base,
u32 percpu_offset, struct device_node *node)
{
    irq_hw_number_t hwirq_base;
    struct gic_chip_data *gic;
    int gic_irqs, irq_base, i;
    ……
    对于root GIC
    hwirq_base = 16;
    gic_irqs = 系统支持的所有的中断数目-16。之所以减去16主要是因为root GIC的0~15号HW interrupt 是for IPI的，因此要去掉。也正因为如此hwirq_base从16开始
    irq_base = irq_alloc_descs(irq_start, 16, gic_irqs, numa_node_id());申请gic_irqs个IRQ资源，从16号开始搜索IRQ number。由于是root GIC，申请的IRQ基本上会从16号开始
    gic->domain = irq_domain_add_legacy(node, gic_irqs, irq_base,
    hwirq_base, &gic_irq_domain_ops, gic);－－－向系统注册irq domain并创建映射
    ……
}
```

很遗憾，在GIC的代码中没有调用标准的注册irq domain的接口函数。要了解其背后的原因，我们需要回到过去。在旧的linux kernel中，ARM体系结构的代码不甚理想。在arch/arm目录充斥了很多board specific的代码，其中定义了很多具体设备相关的静态表格，这些表格规定了各个device使用的资源，当然，其中包括IRQ资源。在这种情况下，各个外设的IRQ是固定的(如果作为驱动程序员的你足够老的话，应该记得很长篇幅的针对IRQ number的宏定义)，也就是说，HW interrupt ID和IRQ number的关系是固定的。一旦关系固定，我们就可以在interupt controller的代码中创建这些映射关系。具体代码如下：

```c
struct irq_domain *irq_domain_add_legacy(struct device_node *of_node,
    unsigned int size,
    unsigned int first_irq,
    irq_hw_number_t first_hwirq,
    const struct irq_domain_ops *ops,
    void *host_data)
{
    struct irq_domain *domain;
    domain = __irq_domain_add(of_node, first_hwirq + size,－－－－注册irq domain
    first_hwirq + size, 0, ops, host_data);
    if (!domain)
        return NULL;
    irq_domain_associate_many(domain, first_irq, first_hwirq, size); －－－创建映射
    return domain;
}
```

这时候，对于这个版本的GIC driver而言，初始化之后，HW interrupt ID和IRQ number的映射关系已经建立，保存在线性lookup table中，size等于GIC支持的中断数目，具体如下：

index 0~15对应的IRQ无效

16号IRQ  <------------------>16号HW interrupt ID

17号IRQ  <------------------>17号HW interrupt ID

……

如果想充分发挥Device Tree的威力，3.14版本中的GIC 代码需要修改。

#### 3、在各个硬件外设的驱动初始化过程中，创建HW interrupt ID和IRQ number的映射关系

我们上面的描述过程中，已经提及：设备的驱动在初始化的时候可以调用irq_of_parse_and_map这个接口函数进行该device node中和中断相关的内容(interrupts和interrupt-parent属性)进行分析，并建立映射关系，具体代码如下：

```c
unsigned int irq_of_parse_and_map(struct device_node *dev, int index)
{
    struct of_phandle_args oirq;
    if (of_irq_parse_one(dev, index, &oirq))－－－－分析device node中的interrupt相关属性
    return 0;
    return irq_create_of_mapping(&oirq);－－－－－创建映射
}
```

我们再来看看irq_create_of_mapping函数如何创建映射：

```c
unsigned int irq_create_of_mapping(struct of_phandle_args *irq_data)
{
    struct irq_domain *domain;
    irq_hw_number_t hwirq;
    unsigned int type = IRQ_TYPE_NONE;
    unsigned int virq;
    domain = irq_data->np ? irq_find_host(irq_data->np) : irq_default_domain;－－A
    if (!domain) {
        return 0;
    }
    if (domain->ops->xlate == NULL)－－－－－－－－－－－－－－B
    hwirq = irq_data->args[0];
    else {
        if (domain->ops->xlate(domain, irq_data->np, irq_data->args,－－－－C
        irq_data->args_count, &hwirq, &type))
        return 0;
    }
    /* Create mapping */
    virq = irq_create_mapping(domain, hwirq);－－－－－－－－D
    if (!virq)
        return virq;
    /* Set type if specified and different than the current one */
    if (type != IRQ_TYPE_NONE &&
        type != irq_get_trigger_type(virq))
        irq_set_irq_type(virq, type);－－－－－－－－－E
    return virq;
}
```

A：这里的代码主要是找到irq domain。这是根据传递进来的参数irq_data的np成员来寻找的，具体定义如下：

```c
struct of_phandle_args {
    struct device_node *np;－－－指向了外设对应的interrupt controller的device node
    int args_count;－－－－－－－该外设定义的interrupt相关属性的个数
    uint32_t args[MAX_PHANDLE_ARGS];－－－－具体的interrupt相当属性的定义
};
```

B：如果没有定义xlate函数，那么取interrupts属性的第一个cell作为HW interrupt ID。

C：解铃还需系铃人，interrupts属性最好由interrupt controller(也就是irq domain)解释。如果xlate函数能够完成属性解析，那么将输出参数hwirq和type，分别表示HW interrupt ID和interupt type(触发方式等)。

D：解析完了，最终还是要调用irq_create_mapping函数来创建HW interrupt ID和IRQ number的映射关系。

E：如果有需要，调用irq_set_irq_type函数设定trigger type

irq_create_mapping函数建立HW interrupt ID和IRQ number的映射关系。该接口函数以irq domain和HW interrupt ID为参数，返回IRQ number。具体的代码如下：

```c
unsigned int irq_create_mapping(struct irq_domain *domain,
    irq_hw_number_t hwirq)
{
    unsigned int hint;
    int virq;
    如果映射已经存在，那么不需要映射，直接返回
    virq = irq_find_mapping(domain, hwirq);
    if (virq) {
        return virq;
    }
    hint = hwirq % nr_irqs;－－－－－－－分配一个IRQ 描述符以及对应的irq number
    if (hint == 0)
        hint++;
    virq = irq_alloc_desc_from(hint, of_node_to_nid(domain->of_node));
    if (virq <= 0)
        virq = irq_alloc_desc_from(1, of_node_to_nid(domain->of_node));
    if (virq <= 0) {
        pr_debug("-> virq allocation failed\n");
        return 0;
    }
    if (irq_domain_associate(domain, virq, hwirq)) {－－－建立mapping
        irq_free_desc(virq);
        return 0;
    }
    return virq;
}
```

对于分配中断描述符这段代码，后续的文章会详细描述。这里简单略过，反正，指向完这段代码，我们就可以或者一个IRQ number以及其对应的中断描述符了。程序注释中没有使用IRQ number而是使用了virtual interrupt number这个术语。virtual interrupt number还是重点理解“virtual”这个词，所谓virtual，其实就是说和具体的硬件连接没有关系了，仅仅是一个number而已。具体建立映射的函数是irq_domain_associate函数，代码如下：

```c
int irq_domain_associate(struct irq_domain *domain, unsigned int virq,
irq_hw_number_t hwirq)
{
    struct irq_data *irq_data = irq_get_irq_data(virq);
    int ret;
    mutex_lock(&irq_domain_mutex);
    irq_data->hwirq = hwirq;
    irq_data->domain = domain;
    if (domain->ops->map) {
        ret = domain->ops->map(domain, virq, hwirq);－－－调用irq domain的map callback函数
    }
    if (hwirq < domain->revmap_size) {
        domain->linear_revmap[hwirq] = virq;－－－－填写线性映射lookup table的数据
    } else {
        mutex_lock(&revmap_trees_mutex);
        radix_tree_insert(&domain->revmap_tree, hwirq, irq_data);－－向radix tree插入一个node
        mutex_unlock(&revmap_trees_mutex);
    }
    mutex_unlock(&irq_domain_mutex);
    irq_clear_status_flags(virq, IRQ_NOREQUEST); －－－该IRQ已经可以申请了，因此clear相关flag
    return 0;
}
```

### 七、将HW interrupt ID转成IRQ number

创建了庞大的HW interrupt ID到IRQ number的mapping DB，最终还是要使用。具体的使用场景是在CPU相关的处理函数中，程序会读取硬件interrupt ID，并转成IRQ number，调用对应的irq event handler。在本章中，我们以一个级联的GIC系统为例，描述转换过程

#### 1、GIC driver初始化

上面已经描述了root GIC的的初始化，我们再来看看second GIC的初始化。具体代码在gic_of_init->gic_init_bases中，如下：

```c
void __init gic_init_bases(unsigned int gic_nr, int irq_start,
void __iomem *dist_base, void __iomem *cpu_base,
u32 percpu_offset, struct device_node *node)
{
    irq_hw_number_t hwirq_base;
    struct gic_chip_data *gic;
    int gic_irqs, irq_base, i;
    ……
    对于second GIC
    hwirq_base = 32;
    gic_irqs = 系统支持的所有的中断数目-32。之所以减去32主要是因为对于second GIC，其0~15号HW interrupt 是for IPI的，因此要去掉。而16~31号HW interrupt 是for PPI的，也要去掉。也正因为如此hwirq_base从32开始
    irq_base = irq_alloc_descs(irq_start, 16, gic_irqs, numa_node_id());申请gic_irqs个IRQ资源，从16号开始搜索IRQ number。由于是second GIC，申请的IRQ基本上会从root GIC申请的最后一个IRQ号+1开始
    gic->domain = irq_domain_add_legacy(node, gic_irqs, irq_base,
    hwirq_base, &gic_irq_domain_ops, gic);－－－向系统注册irq domain并创建映射
    ……
}
```

second GIC初始化之后，该irq domain的HW interrupt ID和IRQ number的映射关系已经建立，保存在线性lookup table中，size等于GIC支持的中断数目，具体如下：

index 0~32对应的IRQ无效

root GIC申请的最后一个IRQ号+1  <------------------>32号HW interrupt ID

root GIC申请的最后一个IRQ号+2  <------------------>33号HW interrupt ID

……

OK，我们回到gic的初始化函数，对于second GIC，还有其他部分的初始化内容：

```c
int __init gic_of_init(struct device_node *node, struct device_node *parent)
{
    ……
    if (parent) {
        irq = irq_of_parse_and_map(node, 0);－－解析second GIC的interrupts属性，并进行mapping，返回IRQ number
        gic_cascade_irq(gic_cnt, irq);－－－设置handler
    }
    ……
}
```

上面的初始化函数去掉和级联无关的代码。对于root GIC，其传入的parent是NULL，因此不会执行级联部分的代码。对于second GIC，它是作为其parent(root GIC)的一个普通的irq source，因此，也需要注册该IRQ的handler。由此可见，非root的GIC的初始化分成了两个部分：一部分是作为一个interrupt controller，执行和root GIC一样的初始化代码。另外一方面，GIC又作为一个普通的interrupt generating device，需要象一个普通的设备驱动一样，注册其中断handler。

irq_of_parse_and_map函数相信大家已经熟悉了，这里不再描述。gic_cascade_irq函数如下：

```c
void __init gic_cascade_irq(unsigned int gic_nr, unsigned int irq)
{
    if (irq_set_handler_data(irq, &gic_data[gic_nr]) != 0)－－－设置handler data
    BUG();
    irq_set_chained_handler(irq, gic_handle_cascade_irq);－－－设置handler
}
```

#### 2、具体如何在中断处理过程中，将HW interrupt ID转成IRQ number

在系统的启动过程中，经过了各个interrupt controller以及各个外设驱动的努力，整个interrupt系统的database(将HW interrupt ID转成IRQ number的数据库，这里的数据库不是指SQL lite或者oracle这样通用数据库软件)已经建立。一旦发生硬件中断，经过CPU architecture相关的中断代码之后，会调用irq handler，该函数的一般过程如下：

(1) 首先找到root interrupt controller对应的irq domain。

(2) 根据HW 寄存器信息和irq domain信息获取HW interrupt ID

(3) 调用irq_find_mapping找到HW interrupt ID对应的irq number

(4) 调用handle_IRQ(对于ARM平台)来处理该irq number

对于级联的情况，过程类似上面的描述，但是需要注意的是在步骤4中不是直接调用该IRQ的hander来处理该irq number因为，这个irq需要各个interrupt controller level上的解析。举一个简单的二阶级联情况：假设系统中有两个interrupt controller，A和B，A是root interrupt controller，B连接到A的13号HW interrupt ID上。在B interrupt controller初始化的时候，除了初始化它作为interrupt controller的那部分内容，还有初始化它作为root interrupt controller A上的一个普通外设这部分的内容。最重要的是调用irq_set_chained_handler设定handler。这样，在上面的步骤4的时候，就会调用13号HW interrupt ID对应的handler(也就是B的handler)，在该handler中，会重复上面的(1)~(4)。

## (三)：IRQ number和中断描述符

### 一、前言

本文主要围绕IRQ number和中断描述符(interrupt descriptor)这两个概念描述通用中断处理过程。第二章主要描述基本概念，包括什么是IRQ number，什么是中断描述符等。第三章描述中断描述符数据结构的各个成员。第四章描述了初始化中断描述符相关的接口API。第五章描述中断描述符相关的接口API。

### 二、基本概念

#### 1、通用中断的代码处理示意图

一个关于通用中断处理的示意图如下：

![](attachment\3.1.gif)

在linux kernel中，对于每一个外设的IRQ都用struct irq_desc来描述，我们称之中断描述符(struct irq_desc)。linux kernel中会有一个数据结构保存了关于所有IRQ的中断描述符信息，我们称之中断描述符DB(上图中红色框图内)。当发生中断后，首先获取触发中断的HW interupt ID，然后通过irq domain翻译成IRQ nuber，然后通过IRQ number就可以获取对应的中断描述符。调用中断描述符中的highlevel irq-events handler来进行中断处理就OK了。而highlevel irq-events handler主要进行下面两个操作：

(1) 调用中断描述符的底层irq chip driver进行mask，ack等callback函数，进行interrupt flow control。

(2) 调用该中断描述符上的action list中的specific handler(我们用这个术语来区分具体中断handler和high level的handler)。这个步骤不一定会执行，这是和中断描述符的当前状态相关，实际上，interrupt flow control是软件(设定一些标志位，软件根据标志位进行处理)和硬件(mask或者unmask interrupt controller等)一起控制完成的。

#### 2、中断的打开和关闭

我们再来看看整个通用中断处理过程中的开关中断情况，开关中断有两种：

(1) 开关local CPU的中断。对于UP，关闭CPU中断就关闭了一切，永远不会被抢占。对于SMP，实际上，没有关全局中断这一说，只能关闭local CPU(代码运行的那个CPU)

(2) 控制interrupt controller，关闭某个IRQ number对应的中断。更准确的术语是mask或者unmask一个 IRQ。

本节主要描述的是第一种，也就是控制CPU的中断。当进入high level handler的时候，CPU的中断是关闭的(硬件在进入IRQ processor mode的时候设定的)。

对于外设的specific handler，旧的内核(2.6.35版本之前)认为有两种：slow handler和fast handle。在request irq的时候，对于fast handler，需要传递IRQF_DISABLED的参数，确保其中断处理过程中是关闭CPU的中断，因为是fast handler，执行很快，即便是关闭CPU中断不会影响系统的性能。但是，并不是每一种外设中断的handler都是那么快(例如磁盘)，因此就有slow handler的概念，说明其在中断处理过程中会耗时比较长。对于这种情况，如果在整个specific handler中关闭CPU中断，对系统的performance会有影响。因此，对于slow handler，在从high level handler转入specific handler中间会根据IRQF_DISABLED这个flag来决定是否打开中断，具体代码如下(来自2.6.23内核)：

```c
irqreturn_t handle_IRQ_event(unsigned int irq, struct irqaction *action)
{
    ……
    if (!(action->flags & IRQF_DISABLED))
    local_irq_enable_in_hardirq();
    ……
}
```

如果没有设定IRQF_DISABLED(slow handler)，则打开本CPU的中断。然而，随着软硬件技术的发展：

(1) 硬件方面，CPU越来越快，原来slow handler也可以很快执行完毕

(2) 软件方面，linux kernel提供了更多更好的bottom half的机制

因此，在新的内核中，比如3.14，IRQF_DISABLED被废弃了。我们可以思考一下，为何要有slow handler?每一个handler不都是应该迅速执行完毕，返回中断现场吗?此外，任意中断可以打断slow handler执行，从而导致中断嵌套加深，对内核栈也是考验。因此，新的内核中在interrupt specific handler中是全程关闭CPU中断的。

### 3、IRQ number

从CPU的角度看，无论外部的Interrupt controller的结构是多么复杂，I do not care，我只关心发生了一个指定外设的中断，需要调用相应的外设中断的handler就OK了。更准确的说是通用中断处理模块不关心外部interrupt controller的组织细节(电源管理模块当然要关注具体的设备(interrupt controller也是设备)的拓扑结构)。一言以蔽之，通用中断处理模块可以用一个线性的table来管理一个个的外部中断，这个表的每个元素就是一个irq描述符，在kernel中定义如下：

```c
struct irq_desc irq_desc[NR_IRQS] __cacheline_aligned_in_smp = {
    [0 ... NR_IRQS-1] = {
        .handle_irq    = handle_bad_irq,
        .depth        = 1,
        .lock        = __RAW_SPIN_LOCK_UNLOCKED(irq_desc->lock),
    }
};
```

系统中每一个连接外设的中断线(irq request line)用一个中断描述符来描述，每一个外设的interrupt request line分配一个中断号(irq number)，系统中有多少个中断线(或者叫做中断源)就有多少个中断描述符(struct irq_desc)。NR_IRQS定义了该硬件平台IRQ的最大数目。

总之，一个静态定义的表格，irq number作为index，每个描述符都是紧密的排在一起，一切看起来很美好，但是现实很残酷的。有些系统可能会定义一个很大的NR_IRQS，但是只是想用其中的若干个，换句话说，这个静态定义的表格不是每个entry都是有效的，有空洞，如果使用静态定义的表格就会导致了内存很大的浪费。为什么会有这种需求?我猜是和各个interrupt controller硬件的interrupt ID映射到irq number的算法有关。在这种情况下，静态表格不适合了，我们改用一个radix tree来保存中断描述符(HW interrupt作为索引)。这时候，每一个中断描述符都是动态分配，然后插入到radix tree中。如果你的系统采用这种策略，那么需要打开CONFIG_SPARSE_IRQ选项。上面的示意图描述的是静态表格的中断描述符DB，如果打开CONFIG_SPARSE_IRQ选项，系统使用Radix tree来保存中断描述符DB，不过概念和静态表格是类似的。

此外，需要注意的是，在旧内核中，IRQ number和硬件的连接有一定的关系，但是，在引入irq domain后，IRQ number已经变成一个单纯的number，和硬件没有任何关系。

## 三、中断描述符数据结构

### 1、底层irq chip相关的数据结构

中断描述符中应该会包括底层irq chip相关的数据结构，linux kernel中把这些数据组织在一起，形成struct irq_data，具体代码如下：

```c
struct irq_data {
    u32            mask;－－－－－－－－－－TODO
    unsigned int        irq;－－－－－－－－IRQ number
    unsigned long        hwirq;－－－－－－－HW interrupt ID
    unsigned int        node;－－－－－－－NUMA node index
    unsigned int        state_use_accessors;－－－－－－－－底层状态，参考IRQD_xxxx
    struct irq_chip        *chip;－－－－－－－－－－该中断描述符对应的irq chip数据结构
    struct irq_domain    *domain;－－－－－－－－该中断描述符对应的irq domain数据结构
    void            *handler_data;－－－－－－－－和外设specific handler相关的私有数据
    void            *chip_data;－－－－－－－－－和中断控制器相关的私有数据
    struct msi_desc        *msi_desc;
    cpumask_var_t        affinity;－－－－－－－和irq affinity相关
};
```

中断有两种形态，一种就是直接通过signal相连，用电平或者边缘触发。另外一种是基于消息的，被称为MSI (Message Signaled Interrupts)。msi_desc是MSI类型的中断相关，这里不再描述。

node成员用来保存中断描述符的内存位于哪一个memory node上。 对于支持NUMA(Non Uniform Memory Access Architecture)的系统，其内存空间并不是均一的，而是被划分成不同的node，对于不同的memory node，CPU其访问速度是不一样的。如果一个IRQ大部分(或者固定)由某一个CPU处理，那么在动态分配中断描述符的时候，应该考虑将内存分配在该CPU访问速度比较快的memory node上。

### 2、irq chip数据结构

Interrupt controller描述符(struct irq_chip)包括了若干和具体Interrupt controller相关的callback函数，我们总结如下：

| 成员名字                                     | 描述                                       |
| ---------------------------------------- | ---------------------------------------- |
| name                                     | 该中断控制器的名字，用于/proc/interrupts中的显示         |
| irq_startup                              | start up 指定的irq domain上的HW interrupt ID。如果不设定的话，default会被设定为enable函数 |
| irq_shutdown                             | shutdown 指定的irq domain上的HW interrupt ID。如果不设定的话，default会被设定为disable函数 |
| irq_enable                               | enable指定的irq domain上的HW interrupt ID。如果不设定的话，default会被设定为unmask函数 |
| irq_disable                              | disable指定的irq domain上的HW interrupt ID。   |
| irq_ack                                  | 和具体的硬件相关，有些中断控制器必须在Ack之后(清除pending的状态)才能接受到新的中断。 |
| irq_mask                                 | mask指定的irq domain上的HW interrupt ID       |
| irq_mask_ack                             | mask并ack指定的irq domain上的HW interrupt ID。  |
| irq_unmask                               | mask指定的irq domain上的HW interrupt ID       |
| irq_eoi                                  | 有些interrupt controler(例如GIC)提供了这样的寄存器接口，让CPU可以通知interrupt controller，它已经处理完一个中断 |
| irq_set_affinity                         | 在SMP的情况下，可以通过该callback函数设定CPU affinity   |
| irq_retrigger                            | 重新触发一次中断，一般用在中断丢失的场景下。如果硬件不支持retrigger，可以使用软件的方法。 |
| irq_set_type                             | 设定指定的irq domain上的HW interrupt ID的触发方式，电平触发还是边缘触发 |
| irq_set_wake                             | 和电源管理相关，用来enable/disable指定的interrupt source作为唤醒的条件。 |
| irq_bus_lock                             | 有些interrupt controller是连接到慢速总线上(例如一个i2c接口的IO expander芯片)，在访问这些芯片的时候需要lock住那个慢速bus(只能有一个client在使用I2C bus) |
| irq_bus_sync_unlock                      | unlock慢速总线                               |
| irq_suspend<br>irq_resume<br>irq_pm_shutdown | 电源管理相关的callback函数                        |
| irq_calc_mask                            | TODO                                     |
| irq_print_chip                           | /proc/interrupts中的信息显示                   |

### 3、中断描述符

在linux kernel中，使用struct irq_desc来描述一个外设的中断，我们称之中断描述符，具体代码如下：

```c
struct irq_desc {
    struct irq_data        irq_data;
    unsigned int __percpu    *kstat_irqs;－－－－－－IRQ的统计信息
    irq_flow_handler_t    handle_irq;－－－－－－－－(1)
    struct irqaction    *action; －－－－－－－－－－－(2)
    unsigned int        status_use_accessors;－－－－－中断描述符的状态，参考IRQ_xxxx
    unsigned int        core_internal_state__do_not_mess_with_it;－－－－(3)
    unsigned int        depth;－－－－－－－－－－(4)
    unsigned int        wake_depth;－－－－－－－－(5)
    unsigned int        irq_count;  －－－－－－－－－(6)
    unsigned long        last_unhandled;
    unsigned int        irqs_unhandled;
    raw_spinlock_t        lock;－－－－－－－－－－－(7)
    struct cpumask        *percpu_enabled;－－－－－－－(8)
    #ifdef CONFIG_SMP
    const struct cpumask    *affinity_hint;－－－－和irq affinity相关，后续单独文档描述
    struct irq_affinity_notify *affinity_notify;
    #ifdef CONFIG_GENERIC_PENDING_IRQ
    cpumask_var_t        pending_mask;
    #endif
    #endif
    unsigned long        threads_oneshot; －－－－－(9)
    atomic_t        threads_active;
    wait_queue_head_t       wait_for_threads;
    #ifdef CONFIG_PROC_FS
    struct proc_dir_entry    *dir;－－－－－－－－该IRQ对应的proc接口
    #endif
    int            parent_irq;
    struct module        *owner;
    const char        *name;
} ____cacheline_internodealigned_in_smp
```

(1) handle_irq就是highlevel irq-events handler，何谓high level?站在高处自然看不到细节。我认为high level是和specific相对，specific handler处理具体的事务，例如处理一个按键中断、处理一个磁盘中断。而high level则是对处理各种中断交互过程的一个抽象，根据下列硬件的不同：

​    (a) 中断控制器

​    (b) IRQ trigger type

highlevel irq-events handler可以分成：

​    (a) 处理电平触发类型的中断handler(handle_level_irq)

​    (b) 处理边缘触发类型的中断handler(handle_edge_irq)

​    (c) 处理简单类型的中断handler(handle_simple_irq)

​    (d) 处理EOI类型的中断handler(handle_fasteoi_irq)

会另外有一份文档对high level handler进行更详细的描述。

(2) action指向一个struct irqaction的链表。如果一个interrupt request line允许共享，那么该链表中的成员可以是多个，否则，该链表只有一个节点。

(3) 这个有着很长名字的符号core_internal_state__do_not_mess_with_it在具体使用的时候被被简化成istate，表示internal state。就像这个名字定义的那样，我们最好不要直接修改它。

```c
#define istate core_internal_state__do_not_mess_with_it
```

(4) 我们可以通过enable和disable一个指定的IRQ来控制内核的并发，从而保护临界区的数据。对一个IRQ进行enable和disable的操作可以嵌套(当然一定要成对使用)，depth是描述嵌套深度的信息。

(5) wake_depth是和电源管理中的wake up source相关。通过irq_set_irq_wake接口可以enable或者disable一个IRQ中断是否可以把系统从suspend状态唤醒。同样的，对一个IRQ进行wakeup source的enable和disable的操作可以嵌套(当然一定要成对使用)，wake_depth是描述嵌套深度的信息。

(6) irq_count、last_unhandled和irqs_unhandled用于处理broken IRQ 的处理。所谓broken IRQ就是由于种种原因(例如错误firmware)，IRQ handler没有定向到指定的IRQ上，当一个IRQ没有被处理的时候，kernel可以为这个没有被处理的handler启动scan过程，让系统中所有的handler来认领该IRQ。

(7) 保护该中断描述符的spin lock。

(8) 一个中断描述符可能会有两种情况，一种是该IRQ是global，一旦disable了该irq，那么对于所有的CPU而言都是disable的。还有一种情况，就是该IRQ是per CPU的，也就是说，在某个CPU上disable了该irq只是disable了本CPU的IRQ而已，其他的CPU仍然是enable的。percpu_enabled是一个描述该IRQ在各个CPU上是否enable成员。

(9) threads_oneshot、threads_active和wait_for_threads是和IRQ thread相关，后续文档会专门描述。

## 四、初始化相关的中断描述符的接口

### 1、静态定义的中断描述符初始化

```c
int __init early_irq_init(void)
{
    int count, i, node = first_online_node;
    struct irq_desc *desc;
    init_irq_default_affinity();
    desc = irq_desc;
    count = ARRAY_SIZE(irq_desc);
    for (i = 0; i < count; i++) {－－－遍历整个lookup table，对每一个entry进行初始化
        desc[i].kstat_irqs = alloc_percpu(unsigned int);－－－分配per cpu的irq统计信息需要的内存
        alloc_masks(&desc[i], GFP_KERNEL, node);－－－分配中断描述符中需要的cpu mask内存
        raw_spin_lock_init(&desc[i].lock);－－－初始化spin lock
        lockdep_set_class(&desc[i].lock, &irq_desc_lock_class);
        desc_set_defaults(i, &desc[i], node, NULL);－－－设定default值
    }
    return arch_early_irq_init();－－－调用arch相关的初始化函数
}
```

2、使用Radix tree的中断描述符初始化

```c
int __init early_irq_init(void)
{
    ……
    initcnt = arch_probe_nr_irqs();－－－体系结构相关的代码来决定预先分配的中断描述符的个数
    if (initcnt > nr_irqs)－－－initcnt是需要在初始化的时候预分配的IRQ的个数
    nr_irqs = initcnt; －－－nr_irqs是当前系统中IRQ number的最大值
    for (i = 0; i < initcnt; i++) {－－－－－－－－预先分配initcnt个中断描述符
        desc = alloc_desc(i, node, NULL);－－－分配中断描述符
        set_bit(i, allocated_irqs);－－－设定已经alloc的flag
        irq_insert_desc(i, desc);－－－－－插入radix tree
    }
    ……
}
```

即便是配置了CONFIG_SPARSE_IRQ选项，在中断描述符初始化的时候，也有机会预先分配一定数量的IRQ。这个数量由arch_probe_nr_irqs决定，对于ARM而言，其arch_probe_nr_irqs定义如下：

```c
int __init arch_probe_nr_irqs(void)
{
    nr_irqs = machine_desc->nr_irqs ? machine_desc->nr_irqs : NR_IRQS;
    return nr_irqs;
}
```

### 3、分配和释放中断描述符

对于使用Radix tree来保存中断描述符DB的linux kernel，其中断描述符是动态分配的，可以使用irq_alloc_descs和irq_free_descs来分配和释放中断描述符。alloc_desc函数也会对中断描述符进行初始化，初始化的内容和静态定义的中断描述符初始化过程是一样的。最大可以分配的ID是IRQ_BITMAP_BITS，定义如下：

```c
#ifdef CONFIG_SPARSE_IRQ
# define IRQ_BITMAP_BITS    (NR_IRQS + 8196)－－－对于Radix tree，除了预分配的，还可以动态
#else                                                                             分配8196个中断描述符
# define IRQ_BITMAP_BITS    NR_IRQS－－－对于静态定义的，IRQ最大值就是NR_IRQS
#endif
```

## 五、和中断控制器相关的中断描述符的接口

这部分的接口主要有两类，irq_desc_get_xxx和irq_set_xxx，由于get接口API非常简单，这里不再描述，主要描述set类别的接口API。此外，还有一些locked版本的set接口API，定义为__irq_set_xxx，这些API的调用者应该已经持有保护irq desc的spinlock，因此，这些locked版本的接口没有中断描述符的spin lock进行操作。这些接口有自己特定的使用场合，这里也不详细描述了。

### 1、接口调用时机

kernel提供了若干的接口API可以让内核其他模块可以操作指定IRQ number的描述符结构。中断描述符中有很多的成员是和底层的中断控制器相关，例如：

(1) 该中断描述符对应的irq chip

(2) 该中断描述符对应的irq trigger type

(3) high level handler

在过去，系统中各个IRQ number是固定分配的，各个IRQ对应的中断控制器、触发类型等也都是清楚的，因此，一般都是在machine driver初始化的时候一次性的进行设定。machine driver的初始化过程会包括中断系统的初始化，在machine driver的中断初始化函数中，会调用本文定义的这些接口对各个IRQ number对应的中断描述符进行irq chip、触发类型的设定。

在引入了device tree、动态分配IRQ number以及irq domain这些概念之后，这些接口的调用时机移到各个中断控制器的初始化以及各个具体硬件驱动初始化过程中，具体如下：

(1) 各个中断控制器定义好自己的struct irq_domain_ops callback函数，主要是map和translate函数。

(2) 在各个具体的硬件驱动初始化过程中，通过device tree系统可以知道自己的中断信息(连接到哪一个interrupt controler、使用该interrupt controller的那个HW interrupt ID，trigger type为何)，调用对应的irq domain的translate进行翻译、解析。之后可以动态申请一个IRQ number并和该硬件外设的HW interrupt ID进行映射，调用irq domain对应的map函数。在map函数中，可以调用本节定义的接口进行中断描述符底层interrupt controller相关信息的设定。

### 2、irq_set_chip

这个接口函数用来设定中断描述符中desc->irq_data.chip成员，具体代码如下：

```c
int irq_set_chip(unsigned int irq, struct irq_chip *chip)
{
    unsigned long flags;
    struct irq_desc *desc = irq_get_desc_lock(irq, &flags, 0); －－－－(1)
    desc->irq_data.chip = chip;
    irq_put_desc_unlock(desc, flags);－－－－－－－－－－－－－－－(2)
    irq_reserve_irq(irq);－－－－－－－－－－－－－－－－－－－－－－(3)
    return 0;
}
```

(1) 获取irq number对应的中断描述符。这里用关闭中断+spin lock来保护中断描述符，flag中就是保存的关闭中断之前的状态flag，后面在(2)中会恢复中断flag。

(3) 前面我们说过，irq number有静态表格定义的，也有radix tree类型的。对于静态定义的中断描述符，没有alloc的概念。但是，对于radix tree类型，需要首先irq_alloc_desc或者irq_alloc_descs来分配一个或者一组IRQ number，在这些alloc函数值，就会set那些那些已经分配的IRQ。对于静态表格而言，其IRQ没有分配，因此，这里通过irq_reserve_irq函数标识该IRQ已经分配，虽然对于CONFIG_SPARSE_IRQ(使用radix tree)的配置而言，这个操作重复了(在alloc的时候已经设定了)。

### 3、irq_set_irq_type

这个函数是用来设定该irq number的trigger type的。

```c
int irq_set_irq_type(unsigned int irq, unsigned int type)
{
    unsigned long flags;
    struct irq_desc *desc = irq_get_desc_buslock(irq, &flags, IRQ_GET_DESC_CHECK_GLOBAL);
    int ret = 0;
    type &= IRQ_TYPE_SENSE_MASK;
    ret = __irq_set_trigger(desc, irq, type);
    irq_put_desc_busunlock(desc, flags);
    return ret;
}
```

来到这个接口函数，第一个问题就是：为何irq_set_chip接口函数使用irq_get_desc_lock来获取中断描述符，而irq_set_irq_type这个函数却需要irq_get_desc_buslock呢?其实也很简单，irq_set_chip不需要访问底层的irq chip(也就是interrupt controller)，但是irq_set_irq_type需要。设定一个IRQ的trigger type最终要调用desc->irq_data.chip->irq_set_type函数对底层的interrupt controller进行设定。这时候，问题来了，对于嵌入SOC内部的interrupt controller，当然没有问题，因为访问这些中断控制器的寄存器memory map到了CPU的地址空间，访问非常的快，因此，关闭中断+spin lock来保护中断描述符当然没有问题，但是，如果该interrupt controller是一个I2C接口的IO expander芯片(这类芯片是扩展的IO，也可以提供中断功能)，这时，让其他CPU进行spin操作太浪费CPU时间了(bus操作太慢了，会spin很久的)。肿么办?当然只能是用其他方法lock住bus了(例如mutex，具体实现是和irq chip中的irq_bus_lock实现相关)。一旦lock住了slow bus，然后就可以关闭中断了(中断状态保存在flag中)。

解决了bus lock的疑问后，还有一个看起来奇奇怪怪的宏：IRQ_GET_DESC_CHECK_GLOBAL。为何在irq_set_chip函数中不设定检查(check的参数是0)，而在irq_set_irq_type接口函数中要设定global的check，到底是什么意思呢?既然要检查，那么检查什么呢?和“global”对应的不是local而是“per CPU”，内核中的宏定义是：IRQ_GET_DESC_CHECK_PERCPU。SMP情况下，从系统角度看，中断有两种形态(或者叫mode)：

(1) 1-N mode。只有1个processor处理中断

(2) N-N mode。所有的processor都是独立的收到中断，如果有N个processor收到中断，那么就有N个处理器来处理该中断。

听起来有些抽象，我们还是用GIC作为例子来具体描述。在GIC中，SPI使用1-N模型，而PPI和SGI使用N-N模型。对于SPI，由于采用了1-N模型，系统(硬件加上软件)必须保证一个中断被一个CPU处理。对于GIC，一个SPI的中断可以trigger多个CPU的interrupt line(如果Distributor中的Interrupt Processor Targets Registers有多个bit被设定)，但是，该interrupt source和CPU的接口寄存器(例如ack register)只有一套，也就是说，这些寄存器接口是全局的，是global的，一旦一个CPU ack(读Interrupt Acknowledge Register，获取interrupt ID)了该中断，那么其他的CPU看到的该interupt source的状态也是已经ack的状态。在这种情况下，如果第二个CPU ack该中断的时候，将获取一个spurious interrupt ID。

对于PPI或者SGI，使用N-N mode，其interrupt source的寄存器是per CPU的，也就是每个CPU都有自己的、针对该interrupt source的寄存器接口(这些寄存器叫做banked register)。一个CPU 清除了该interrupt source的pending状态，其他的CPU感知不到这个变化，它们仍然认为该中断是pending的。

对于irq_set_irq_type这个接口函数，它是for 1-N mode的interrupt source使用的。如果底层设定该interrupt是per CPU的，那么irq_set_irq_type要返回错误。

### 4、irq_set_chip_data

每个irq chip总有自己私有的数据，我们称之chip data。具体设定chip data的代码如下：

```c
int irq_set_chip_data(unsigned int irq, void *data)
{
    unsigned long flags;
    struct irq_desc *desc = irq_get_desc_lock(irq, &flags, 0);
    desc->irq_data.chip_data = data;
    irq_put_desc_unlock(desc, flags);
    return 0;
}
```

多么清晰、多么明了，需要文字继续描述吗?

### 5、设定high level handler

这是中断处理的核心内容，__irq_set_handler就是设定high level handler的接口函数，不过一般不会直接调用，而是通过irq_set_chip_and_handler_name或者irq_set_chip_and_handler来进行设定。具体代码如下：

```c
void __irq_set_handler(unsigned int irq, irq_flow_handler_t handle, int is_chained, const char *name)
{
    unsigned long flags;
    struct irq_desc *desc = irq_get_desc_buslock(irq, &flags, 0);
    ……
    desc->handle_irq = handle;
    desc->name = name;
    if (handle != handle_bad_irq && is_chained) {
        irq_settings_set_noprobe(desc);
        irq_settings_set_norequest(desc);
        irq_settings_set_nothread(desc);
        irq_startup(desc, true);
    }
out:
    irq_put_desc_busunlock(desc, flags);
}
```

理解这个函数的关键是在is_chained这个参数。这个参数是用在interrupt级联的情况下。例如中断控制器B级联到中断控制器A的第x个interrupt source上。那么对于A上的x这个interrupt而言，在设定其IRQ handler参数的时候要设定is_chained参数等于1，由于这个interrupt source用于级联，因此不能probe、不能被request(已经被中断控制器B使用了)，不能被threaded(具体中断线程化的概念在其他文档中描述)

## (四)：High level irq event handler

### 一、前言

当外设触发一次中断后，一个大概的处理过程是：

1、 具体CPU architecture相关的模块会进行现场保护，然后调用machine driver对应的中断处理handler

2、 machine driver对应的中断处理handler中会根据硬件的信息获取HW interrupt ID，并且通过irq domain模块翻译成IRQ number

3、 调用该IRQ number对应的high level irq event handler，在这个high level的handler中，会通过和interupt controller交互，进行中断处理的flow control(处理中断的嵌套、抢占等)，当然最终会遍历该中断描述符的IRQ action list，调用外设的specific handler来处理该中断

4、 具体CPU architecture相关的模块会进行现场恢复。

上面的1、4这两个步骤在linux kernel的中断子系统之(六)：ARM中断处理过程中已经有了较为细致的描述，步骤2在linux kernel的中断子系统之(二)：irq domain介绍中介绍，本文主要描述步骤3，也就是linux中断子系统的high level irq event handler。

注：这份文档充满了猜测和空想，很多地方描述可能是有问题的，不过我还是把它发出来，抛砖引玉，希望可以引发大家讨论。

#### 一、 如何进入high level irq event handler

1、 从具体CPU architecture的中断处理到machine相关的处理模块

说到具体的CPU，我们还是用ARM为例好了。对于ARM，我们在ARM中断处理文档中已经有了较为细致的描述。这里我们看看如何从从具体CPU的中断处理到machine相关的处理模块 ，其具体代码如下：

```assembly
.macro    irq_handler
#ifdef CONFIG_MULTI_IRQ_HANDLER
ldr    r1, =handle_arch_irq
mov    r0, sp
adr    lr, BSYM(9997f)
ldr    pc, [r1]
#else
arch_irq_handler_default
#endif
9997:
.endm
```

其实，直接从CPU的中断处理跳转到通用中断处理模块是不可能的，中断处理不可能越过interrupt controller这个层次。一般而言，通用中断处理模块会提供一些通用的中断代码处理库，然后由interrupt controller这个层次的代码调用这些通用中断处理的完成整个的中断处理过程。“interrupt controller这个层次的代码”是和硬件中断系统设计相关的，例如：系统中有多少个interrupt contrller，每个interrupt controller是如何控制的?它们是如何级联的?我们称这些相关的驱动模块为machine interrupt driver。

在上面的代码中，如果配置了MULTI_IRQ_HANDLER的话，ARM中断处理则直接跳转到一个叫做handle_arch_irq函数，如果系统中只有一个类型的interrupt controller(可能是多个interrupt controller，例如使用两个级联的GIC)，那么handle_arch_irq可以在interrupt controller初始化的时候设定。代码如下：

```c
……
if (gic_nr == 0) {
    set_handle_irq(gic_handle_irq);
}
……
```

gic_nr是GIC的编号，linux kernel初始化过程中，每发现一个GIC，都是会指向GIC driver的初始化函数的，不过对于第一个GIC，gic_nr等于0，对于第二个GIC，gic_nr等于1。当然handle_arch_irq这个函数指针不是per CPU的变量，是全部CPU共享的，因此，初始化一次就OK了。

当使用多种类型的interrupt controller的时候(例如HW 系统使用了S3C2451这样的SOC，这时候，系统有两种interrupt controller，一种是GPIO type，另外一种是SOC上的interrupt controller)，则不适合在interrupt controller中进行设定，这时候，可以考虑在machine driver中设定。在这种情况下，handle_arch_irq 这个函数是在setup_arch函数中根据machine driver设定，具体如下：

```c
handle_arch_irq = mdesc->handle_irq;
```

关于MULTI_IRQ_HANDLER这个配置项，我们可以再多说几句。当然，其实这个配置项的名字已经出卖它了。multi irq handler就是说系统中有多个irq handler，可以在run time的时候指定。为何要run time的时候，从多个handler中选择一个呢?HW interrupt block难道不是固定的吗?我的理解(猜想)是：一个kernel的image支持多个HW platform，对于不同的HW platform，在运行时检查HW platform的类型，设定不同的irq handler。

2、 interrupt controller相关的代码

我们还是以2个级联的GIC为例来描述interrupt controller相关的代码。代码如下：

```c
static asmlinkage void __exception_irq_entry gic_handle_irq(struct pt_regs *regs)
{
    u32 irqstat, irqnr;
    struct gic_chip_data *gic = &gic_data[0];－－－－－获取root GIC的硬件描述符
    void __iomem *cpu_base = gic_data_cpu_base(gic); 获取root GIC mapping到CPU地址空间的信息
    do {
        irqstat = readl_relaxed(cpu_base + GIC_CPU_INTACK);－－－获取HW interrupt ID
        irqnr = irqstat & ~0x1c00;
        if (likely(irqnr > 15 && irqnr < 1021)) {－－－－SPI和PPI的处理
            irqnr = irq_find_mapping(gic->domain, irqnr);－－－将HW interrupt ID转成IRQ number
            handle_IRQ(irqnr, regs);－－－－处理该IRQ number
            continue;
        }
        if (irqnr < 16) {－－－－－IPI类型的中断处理
            writel_relaxed(irqstat, cpu_base + GIC_CPU_EOI);
#ifdef CONFIG_SMP
            handle_IPI(irqnr, regs);
#endif
            continue;
        }
        break;
    } while (1);
}
```

更多关于GIC相关的信息，请参考linux kernel的中断子系统之(七)：GIC代码分析。对于ARM处理器，handle_IRQ代码如下：

```c
void handle_IRQ(unsigned int irq, struct pt_regs *regs)
{
    ……
    generic_handle_irq(irq);
    ……
}
```

3、 调用high level handler

调用high level handler的代码逻辑非常简单，如下：

```c
int generic_handle_irq(unsigned int irq)
{
    struct irq_desc *desc = irq_to_desc(irq); －－－通过IRQ number获取该irq的描述符
    if (!desc)
    return -EINVAL;
    generic_handle_irq_desc(irq, desc);－－－－调用high level的irq handler来处理该IRQ
    return 0;
}
static inline void generic_handle_irq_desc(unsigned int irq, struct irq_desc *desc)
{
    desc->handle_irq(irq, desc);
}
```

### 二、理解high level irq event handler需要的知识准备

1、 自动探测IRQ

一个硬件驱动可以通过下面的方法进行自动探测它使用的IRQ：

```c
unsigned long irqs;
int irq;
irqs = probe_irq_on();－－－－－－－－启动IRQ自动探测
驱动那个打算自动探测IRQ的硬件产生中断
irq = probe_irq_off(irqs);－－－－－－－结束IRQ自动探测
```

如果能够自动探测到IRQ，上面程序中的irq(probe_irq_off的返回值)就是自动探测的结果。后续程序可以通过request_threaded_irq申请该IRQ。probe_irq_on函数主要的目的是返回一个32 bit的掩码，通过该掩码可以知道可能使用的IRQ number有哪些，具体代码如下：

```c
unsigned long probe_irq_on(void)
{
    ……
    for_each_irq_desc_reverse(i, desc) { －－－－scan 从nr_irqs-1 到0 的中断描述符
        raw_spin_lock_irq(&desc->lock);
        if (!desc->action && irq_settings_can_probe(desc)) {－－－－－－－－(1)
            desc->istate |= IRQS_AUTODETECT | IRQS_WAITING;－－－－－(2)
            if (irq_startup(desc, false))
            desc->istate |= IRQS_PENDING;
        }
        raw_spin_unlock_irq(&desc->lock);
    }
    msleep(100); －－－－－－－－－－－－－－－－－－－－－－－－－－(3)
    for_each_irq_desc(i, desc) {
        raw_spin_lock_irq(&desc->lock);
        if (desc->istate & IRQS_AUTODETECT) {－－－－－－－－－－－－(4)
            if (!(desc->istate & IRQS_WAITING)) {
                desc->istate &= ~IRQS_AUTODETECT;
                irq_shutdown(desc);
            } else
                if (i < 32)－－－－－－－－－－－－－－－－－－－－－－－－(5)
                    mask |= 1 << i;
        }
        raw_spin_unlock_irq(&desc->lock);
    }
    return mask;
}
```

(1) 那些能自动探测IRQ的中断描述符需要具体两个条件：

a、 该中断描述符还没有通过request_threaded_irq或者其他方式申请该IRQ的specific handler(也就是irqaction数据结构)

b、 该中断描述符允许自动探测(不能设定IRQ_NOPROBE)

(2) 如果满足上面的条件，那么该中断描述符属于备选描述符。设定其internal state为IRQS_AUTODETECT | IRQS_WAITING。IRQS_AUTODETECT表示本IRQ正处于自动探测中。

(3) 在等待过程中，系统仍然允许，各种中断依然会触发。在各种high level irq event handler中，总会有如下的代码：

```c
desc->istate &= ~(IRQS_REPLAY | IRQS_WAITING);
```

这里会清除IRQS_WAITING状态。

(4) 这时候，我们还没有控制那个想要自动探测IRQ的硬件产生中断，因此处于自动探测中，并且IRQS_WAITING并清除的一定不是我们期待的IRQ(可能是spurious interrupts导致的)，这时候，clear IRQS_AUTODETECT，shutdown该IRQ。

(5) 最大探测的IRQ是31(mask是一个32 bit的value)，mask返回的是可能的irq掩码。

我们再来看看probe_irq_off的代码：

```c
int probe_irq_off(unsigned long val)
{
    int i, irq_found = 0, nr_of_irqs = 0;
    struct irq_desc *desc;
    for_each_irq_desc(i, desc) {
        raw_spin_lock_irq(&desc->lock);
        if (desc->istate & IRQS_AUTODETECT) {－－－－只有处于IRQ自动探测中的描述符才会被处理
            if (!(desc->istate & IRQS_WAITING)) {－－－－找到一个潜在的中断描述符
                if (!nr_of_irqs)
                    irq_found = i;
                nr_of_irqs++;
            }
            desc->istate &= ~IRQS_AUTODETECT; －－－－IRQS_WAITING没有被清除，说明该描述符
            irq_shutdown(desc);                                     不是自动探测的那个，shutdown之
        }
        raw_spin_unlock_irq(&desc->lock);
    }
    mutex_unlock(&probing_active);
    if (nr_of_irqs > 1) －－－－－－如果找到多于1个的IRQ，说明探测失败，返回负的IRQ个数信息
    irq_found = -irq_found;
    return irq_found;
}
```

因为在调用probe_irq_off已经触发了自动探测IRQ的那个硬件中断，因此在该中断的high level handler的执行过程中，该硬件对应的中断描述符的IRQS_WAITING标致应该已经被清除，因此probe_irq_off函数scan中断描述符DB，找到处于auto probe中，而且IRQS_WAITING标致被清除的那个IRQ。如果找到一个，那么探测OK，返回该IRQ number，如果找到多个，说明探测失败，返回负的IRQ个数信息，没有找到的话，返回0。

2、 resend一个中断

一个ARM SOC总是有很多的GPIO，有些GPIO可以提供中断功能，这些GPIO的中断可以配置成level trigger或者edge trigger。一般而言，大家都更喜欢用level trigger的中断。有的SOC只能是有限个数的GPIO可以配置成电平中断，因此，在项目初期进行pin define的时候，大家都在争抢电平触发的GPIO。

电平触发的中断有什么好处呢?电平触发的中断很简单、直接，只要硬件检测到硬件事件(例如有数据到来)，其assert指定的电平信号，CPU ack该中断后，电平信号消失。但是对于边缘触发的中断，它是用一个上升沿或者下降沿告知硬件的状态，这个状态不是一个持续的状态，如果软件处理不好，容易丢失中断。

什么时候会resend一个中断呢?我们考虑一个简单的例子：

(1) CPU A上正在处理x外设的中断

(2) x外设的中断再次到来(CPU A已经ack该IRQ，因此x外设的中断可以再次触发)，这时候其他CPU会处理它(mask and ack)，并设置该中断描述符是pending状态，并委托CPU A处理该pending状态的中断。需要注意的是CPU已经ack了该中断，因此该中断的硬件状态已经不是pending状态，无法触发中断了，这里的pending状态是指中断描述符的软件状态。

(3) CPU B上由于同步的需求，disable了x外设的IRQ，这时候，CPU A没有处理pending状态的x外设中断就离开了中断处理过程。

(4) 当enable x外设的IRQ的时候，需要检测pending状态以便resend该中断，否则，该中断会丢失的

具体代码如下：

```c
void check_irq_resend(struct irq_desc *desc, unsigned int irq)
{
    if (irq_settings_is_level(desc)) {－－－－－－－电平中断不存在resend的问题
        desc->istate &= ~IRQS_PENDING;
        return;
    }
    if (desc->istate & IRQS_REPLAY)－－－－如果已经设定resend的flag，退出就OK了，这个应该
        return;                                                和irq的enable disable能多层嵌套相关
    if (desc->istate & IRQS_PENDING) {－－－－－－－如果有pending的flag则进行处理
        desc->istate &= ~IRQS_PENDING;
        desc->istate |= IRQS_REPLAY; －－－－－－设置retrigger标志
        if (!desc->irq_data.chip->irq_retrigger ||
        !desc->irq_data.chip->irq_retrigger(&desc->irq_data)) {－－－－调用底层irq chip的callback
#ifdef CONFIG_HARDIRQS_SW_RESEND
            也可以使用软件手段来完成resend一个中断，具体代码省略，有兴趣大家可以自己看看
#endif
        }
    }
}
```

在各种high level irq event handler中，总会有如下的代码：

```c
desc->istate &= ~(IRQS_REPLAY | IRQS_WAITING);
```

这里会清除IRQS_REPLAY状态，表示该中断已经被retrigger，一次resend interrupt的过程结束。

3、 unhandled interrupt和spurious interrupt

在中断处理的最后，总会有一段代码如下：

```c
irqreturn_t
handle_irq_event_percpu(struct irq_desc *desc, struct irqaction *action)
{
    ……
    if (!noirqdebug)
        note_interrupt(irq, desc, retval);
    return retval;
}
```

note_interrupt就是进行unhandled interrupt和spurious interrupt处理的。对于这类中断，linux kernel有一套复杂的机制来处理，你可以通过command line参数(noirqdebug)来控制开关该功能。

当发生了一个中断，但是没有被处理(有两种可能，一种是根本没有注册的specific handler，第二种是有handler，但是handler否认是自己对应的设备触发的中断)，怎么办?毫无疑问这是一个异常状况，那么kernel是否要立刻采取措施将该IRQ disable呢?也不太合适，毕竟interrupt request信号线是允许共享的，直接disable该IRQ有可能会下手太狠，kernel采取了这样的策略：如果该IRQ触发了100,000次，但是99,900次没有处理，在这种条件下，我们就是disable这个interrupt request line。多么有情有义的策略啊!相关的控制数据在中断描述符中，如下：

```c
struct irq_desc {
    ……
    unsigned int        irq_count;－－－－－－－－记录发生的中断的次数，每100,000则回滚
    unsigned long        last_unhandled;－－－－－上一次没有处理的IRQ的时间点
    unsigned int        irqs_unhandled;－－－－－－没有处理的次数
    ……
}
```
irq_count和irqs_unhandled都是比较直观的，为何要记录unhandled interrupt发生的时间呢?我们来看具体的代码。具体的相关代码位于note_interrupt中，如下：

```c
void note_interrupt(unsigned int irq, struct irq_desc *desc,  irqreturn_t action_ret)
{
    if (desc->istate & IRQS_POLL_INPROGRESS ||  irq_settings_is_polled(desc))
        return;
    if (action_ret == IRQ_WAKE_THREAD)－－－－handler返回IRQ_WAKE_THREAD是正常情况
        return;
    if (bad_action_ret(action_ret)) {－－－－－报告错误，这些是由于specific handler的返回错误导致的
        report_bad_irq(irq, desc, action_ret);
        return;
    }
    if (unlikely(action_ret == IRQ_NONE)) {－－－－－－－是unhandled interrupt
        if (time_after(jiffies, desc->last_unhandled + HZ/10))－－－(1)
            desc->irqs_unhandled = 1;－－－重新开始计数
        else
            desc->irqs_unhandled++;－－－判定为unhandled interrupt，计数加一
        desc->last_unhandled = jiffies;－－－－－－－保存本次unhandled interrupt对应的jiffies时间
    }
    if (unlikely(try_misrouted_irq(irq, desc, action_ret))) {－－－是否启动Misrouted IRQ fixup
        int ok = misrouted_irq(irq);
        if (action_ret == IRQ_NONE)
        desc->irqs_unhandled -= ok;
    }
    desc->irq_count++;
    if (likely(desc->irq_count < 100000))－－－－－－－－－－－(2)
    return;
    desc->irq_count = 0;
    if (unlikely(desc->irqs_unhandled > 99900)) {－－－－－－－－(3)
        __report_bad_irq(irq, desc, action_ret);－－－报告错误
        desc->istate |= IRQS_SPURIOUS_DISABLED;
        desc->depth++;
        irq_disable(desc);
        mod_timer(&poll_spurious_irq_timer,－－－－－－－－－－(4)
        jiffies + POLL_SPURIOUS_IRQ_INTERVAL);
    }
    desc->irqs_unhandled = 0;
}
```

(1) 是否是一次有效的unhandled interrupt还要根据时间来判断。一般而言，当硬件处于异常状态的时候往往是非常短的时间触发非常多次的中断，如果距离上次unhandled interrupt的时间超过了10个jiffies(如果HZ=100，那么时间就是100ms)，那么我们要把irqs_unhandled重新计数。如果不这么处理的话，随着时间的累计，最终irqs_unhandled可能会达到99900次的，从而把这个IRQ错误的推上了审判台。

(2) irq_count每次都会加一，记录IRQ被触发的次数。但只要大于100000才启动 step (3)中的检查。一旦启动检查，irq_count会清零，irqs_unhandled也会清零，进入下一个检查周期。

(3) 如果满足条件(IRQ触发了100,000次，但是99,900次没有处理)，disable该IRQ。

(4) 启动timer，轮询整个系统中的handler来处理这个中断(轮询啊，绝对是真爱啊)。这个timer的callback函数定义如下：

```c
static void poll_spurious_irqs(unsigned long dummy)
{
    struct irq_desc *desc;
    int i;
    if (atomic_inc_return(&irq_poll_active) != 1)－－－－确保系统中只有一个excuting thread进入临界区
        goto out;
    irq_poll_cpu = smp_processor_id(); －－－－记录当前正在polling的CPU
    for_each_irq_desc(i, desc) {－－－－－－遍历所有的中断描述符
        unsigned int state;
        if (!i)－－－－－－－－－－－－－越过0号中断描述符。对于X86，这是timer的中断
            continue;
        /* Racy but it doesn't matter */
        state = desc->istate;
        barrier();
        if (!(state & IRQS_SPURIOUS_DISABLED))－－－－名花有主的那些就不必考虑了
            continue;
        local_irq_disable();
        try_one_irq(i, desc, true);－－－－－－－－－OK，尝试一下是不是可以处理
        local_irq_enable();
    }
out:
    atomic_dec(&irq_poll_active);
    mod_timer(&poll_spurious_irq_timer,－－－－－－－－一旦触发了该timer，就停不下来
    jiffies + POLL_SPURIOUS_IRQ_INTERVAL);
}
```

### 三、和high level irq event handler相关的硬件描述

1、 CPU layer和Interrupt controller之间的接口

从逻辑层面上看，CPU和interrupt controller之间的接口包括：

(1) 触发中断的signal。一般而言，这个(些)信号是电平触发的。对于ARM CPU，它是nIRQ和nFIQ信号线，对于X86，它是INT和NMI信号线，对于PowerPC，这些信号线包括MC(machine check)、CRIT(critical interrupt)和NON-CRIT(Non critical interrupt)。对于linux kernel的中断子系统，我们只使用其中一个信号线(例如对于ARM而言，我们只使用nIRQ这个信号线)。这样，从CPU层面看，其逻辑动作非常的简单，不区分优先级，触发中断的那个信号线一旦assert，并且CPU没有mask中断，那么软件就会转到一个异常向量执行，完毕后返回现场。

(2) Ack中断的signal。这个signal可能是物理上的一个连接CPU和interrupt controller的铜线，也可能不是。对于X86+8259这样的结构，Ack中断的signal就是nINTA信号线，对于ARM+GIC而言，这个信号就是总线上的一次访问(读Interrupt Acknowledge Register寄存器)。CPU ack中断标识cpu开启启动中断服务程序(specific handler)去处理该中断。对于X86而言，ack中断可以让8259将interrupt vector数据送到数据总线上，从而让CPU获取了足够的处理该中断的信息。对于ARM而言，ack中断的同时也就是获取了发生中断的HW interrupt ID，总而言之，ack中断后，CPU获取了足够开启执行中断处理的信息。

(3) 结束中断(EOI，end of interrupt)的signal。这个signal用来标识CPU已经完成了对该中断的处理(specific handler或者ISR，interrupt serivce routine执行完毕)。实际的物理形态这里就不描述了，和ack中断signal是类似的。

(4) 控制总线和数据总线接口。通过这些接口，CPU可以访问(读写)interrupt controller的寄存器。

2、 Interrupt controller和Peripheral device之间的接口

所有的系统中，Interrupt controller和Peripheral device之间的接口都是一个Interrupt Request信号线。外设通过这个信号线上的电平或者边缘向CPU(实际上是通过interrupt controller)申请中断服务。

### 四、几种典型的high level irq event handler

本章主要介绍几种典型的high level irq event handler，在进行high level irq event handler的设定的时候需要注意，不是外设使用电平触发就选用handle_level_irq，选用什么样的high level irq event handler是和Interrupt controller的行为以及外设电平触发方式决定的。介绍每个典型的handler之前，我会简单的描述该handler要求的硬件行为，如果该外设的中断系统符合这个硬件行为，那么可以选择该handler为该中断的high level irq event handler。

1、边缘触发的handler。

使用handle_edge_irq这个handler的硬件中断系统行为如下：

![](attachment\4.1.gif)

我们以上升沿为例描述边缘中断的处理过程(下降沿的触发是类似的)。当interrupt controller检测到了上升沿信号，会将该上升沿状态(pending)锁存在寄存器中，并通过中断的signal向CPU触发中断。需要注意：这时候，外设和interrupt controller之间的interrupt request信号线会保持高电平，这也就意味着interrupt controller不可能检测到新的中断信号(本身是高电平，无法形成上升沿)。这个高电平信号会一直保持到软件ack该中断(调用irq chip的irq_ack callback函数)。ack之后，中断控制器才有可能继续探测上升沿，触发下一次中断。

ARM+GIC组成的系统不符合这个类型。虽然GIC提供了IAR(Interrupt Acknowledge Register)寄存器来让ARM来ack中断，但是，在调用high level handler之前，中断处理程序需要通过读取IAR寄存器获得HW interrpt ID并转换成IRQ number，因此实际上，对于GIC的irq chip，它是无法提供本场景中的irq_ack函数的。很多GPIO type的interrupt controller符合上面的条件，它们会提供pending状态寄存器，读可以获取pending状态，而向pending状态寄存器写1可以ack该中断，让interrupt controller可以继续触发下一次中断。

handle_edge_irq代码如下：

```c
void handle_edge_irq(unsigned int irq, struct irq_desc *desc)
{
    raw_spin_lock(&desc->lock); －－－－－－－－－－－－－－－－－(0)
    desc->istate &= ~(IRQS_REPLAY | IRQS_WAITING);－－－－参考上一章的描述
    if (unlikely(irqd_irq_disabled(&desc->irq_data) ||－－－－－－－－－－－(1)
        irqd_irq_inprogress(&desc->irq_data) || !desc->action)) {
        if (!irq_check_poll(desc)) {
            desc->istate |= IRQS_PENDING;
            mask_ack_irq(desc);
            goto out_unlock;
        }
    }
    kstat_incr_irqs_this_cpu(irq, desc); －－－更新该IRQ统计信息
    desc->irq_data.chip->irq_ack(&desc->irq_data); －－－－－－－－－(2)
    do {
        if (unlikely(!desc->action)) { －－－－－－－－－－－－－－－－－(3)
            mask_irq(desc);
            goto out_unlock;
        }
        if (unlikely(desc->istate & IRQS_PENDING)) { －－－－－－－－－(4)
            if (!irqd_irq_disabled(&desc->irq_data) &&
                irqd_irq_masked(&desc->irq_data))
                unmask_irq(desc);
        }
        handle_irq_event(desc); －－－－－－－－－－－－－－－－－－－(5)
    } while ((desc->istate & IRQS_PENDING) &&
    !irqd_irq_disabled(&desc->irq_data)); －－－－－－－－－－－－－(6)
out_unlock:
    raw_spin_unlock(&desc->lock); －－－－－－－－－－－－－－－－－(7)
}
```

(0) 这时候，中断仍然是关闭的，因此不会有来自本CPU的并发，使用raw spin lock就防止其他CPU上对该IRQ的中断描述符的访问。针对该spin lock，我们直观的感觉是raw_spin_lock和(7)中的raw_spin_unlock是成对的，实际上并不是，handle_irq_event中的代码是这样的：

```c
irqreturn_t handle_irq_event(struct irq_desc *desc)
{
    raw_spin_unlock(&desc->lock); －－－－－－－和上面的(0)对应
    处理具体的action list
    raw_spin_lock(&desc->lock);－－－－－－－－和上面的(7)对应
}
```

实际上，由于在handle_irq_event中处理action list的耗时还是比较长的，因此处理具体的action list的时候并没有持有中断描述符的spin lock。在如果那样的话，其他CPU在对中断描述符进行操作的时候需要spin的时间会很长的。

(1) 判断是否需要执行下面的action list的处理。这里分成几种情况：

a、 该中断事件已经被其他的CPU处理了

b、 该中断被其他的CPU disable了

c、 该中断描述符没有注册specific handler。这个比较简单，如果没有irqaction，根本没有必要调用action list的处理

如果该中断事件已经被其他的CPU处理了，那么我们仅仅是设定pending状态(为了委托正在处理的该中断的那个CPU进行处理)，mask_ack_irq该中断并退出就OK了，并不做具体的处理。另外正在处理该中断的CPU会检查pending状态，并进行处理的。同样的，如果该中断被其他的CPU disable了，本就不应该继续执行该中断的specific handler，我们也是设定pending状态，mask and ack中断就退出了。当其他CPU的代码离开临界区，enable 该中断的时候，软件会检测pending状态并resend该中断。

这里的irq_check_poll代码如下：

```c
static bool irq_check_poll(struct irq_desc *desc)
{
    if (!(desc->istate & IRQS_POLL_INPROGRESS))
        return false;
    return irq_wait_for_poll(desc);
}
```

IRQS_POLL_INPROGRESS标识了该IRQ正在被polling(上一章有描述)，如果没有被轮询，那么返回false，进行正常的设定pending标记、mask and ack中断。如果正在被轮询，那么需要等待poll结束。

(2) ack该中断。对于中断控制器，一旦被ack，表示该外设的中断被enable，硬件上已经准备好触发下一次中断了。再次触发的中断会被调度到其他的CPU上。现在，我们可以再次回到步骤(1)中，为什么这里用mask and ack而不是单纯的ack呢?如果单纯的ack则意味着后续中断还是会触发，这时候怎么处理?在pending+in progress的情况下，我们要怎么处理?记录pending的次数，有意义吗?由于中断是完全异步的，也有可能pending的标记可能在另外的CPU上已经修改为replay的标记，这时候怎么办?当事情变得复杂的时候，那一定是本来方向就错了，因此，mask and ack就是最好的策略，我已经记录了pending状态，不再考虑pending嵌套的情况。

(3) 在调用specific handler处理具体的中断的时候，由于不持有中断描述符的spin lock，因此其他CPU上有可能会注销其specific handler，因此do while循环之后，desc->action有可能是NULL，如果是这样，那么mask irq，然后退出就OK了

(4) 如果中断描述符处于pending状态，那么一定是其他CPU上又触发了该interrupt source的中断，并设定了pending状态，“委托”本CPU进行处理，这时候，需要把之前mask住的中断进行unmask的操作。一旦unmask了该interrupt source，后续的中断可以继续触发，由其他的CPU处理(仍然是设定中断描述符的pending状态，委托当前正在处理该中断请求的那个CPU进行处理)。

(5) 处理该中断请求事件

```c
irqreturn_t handle_irq_event(struct irq_desc *desc)
{
    struct irqaction *action = desc->action;
    irqreturn_t ret;
    desc->istate &= ~IRQS_PENDING;－－－－CPU已经准备处理该中断了，因此，清除pending状态
    irqd_set(&desc->irq_data, IRQD_IRQ_INPROGRESS);－－设定INPROGRESS的flag
    raw_spin_unlock(&desc->lock);
    ret = handle_irq_event_percpu(desc, action); －－－遍历action list，调用specific handler
    raw_spin_lock(&desc->lock);
    irqd_clear(&desc->irq_data, IRQD_IRQ_INPROGRESS);－－－处理完成，清除INPROGRESS标记
    return ret;
}
```

(6) 只要有pending标记，就说明该中断还在pending状态，需要继续处理。当然，如果有其他的CPU disable了该interrupt source，那么本次中断结束处理。

2、电平触发的handler

使用handle_level_irq这个handler的硬件中断系统行为如下：

/ dingjian

我们以高电平触发为例。当interrupt controller检测到了高电平信号，并通过中断的signal向CPU触发中断。这时候，对中断控制器进行ack并不能改变interrupt request signal上的电平状态，一直要等到执行具体的中断服务程序(specific handler)，对外设进行ack的时候，电平信号才会恢复成低电平。在对外设ack之前，中断状态一直是pending的，如果没有mask中断，那么中断控制器就会assert CPU。

handle_level_irq的代码如下：

```c
void handle_level_irq(unsigned int irq, struct irq_desc *desc)
{
    raw_spin_lock(&desc->lock);
    mask_ack_irq(desc); －－－－－－－－－－－－－－－－－－－－－(1)
    if (unlikely(irqd_irq_inprogress(&desc->irq_data)))－－－－－－－－－(2)
        if (!irq_check_poll(desc))
            goto out_unlock;
    desc->istate &= ~(IRQS_REPLAY | IRQS_WAITING);－－和retrigger中断以及自动探测IRQ相关
    kstat_incr_irqs_this_cpu(irq, desc);
    if (unlikely(!desc->action || irqd_irq_disabled(&desc->irq_data))) {－－－－－(3)
        desc->istate |= IRQS_PENDING;
        goto out_unlock;
    }
    handle_irq_event(desc);
    cond_unmask_irq(desc); －－－－－－－－－－－－－－(4)
out_unlock:
    raw_spin_unlock(&desc->lock);
}
```

(1) 考虑CPU<------>interrupt controller<------>device这样的连接方式中，我们认为high level handler主要是和interrupt controller交互，而specific handler(request_irq注册的那个)是和device进行交互。Level类型的中断的特点就是只要外设interrupt request line的电平状态是有效状态，对于interrupt controller，该外设的interrupt总是active的。由于外设检测到了事件(比如数据到来了)，因此assert了指定的电平信号，这个电平信号会一直保持，直到软件清除了外设的状态寄存器。但是，high level irq event handler这个层面只能操作Interrupt controller，不能操作具体外设的寄存器(那应该属于具体外设的specific interrupt handler处理内容，该handler会挂入中断描述符中的IRQ action list)。直到在具体的中断服务程序(specific handler中)操作具体外设的寄存器，才能让这个asserted电平信号消息。

正是因为level trigger的这个特点，因此，在high level handler中首先mask并ack该IRQ。这一点和边缘触发的high level handler有显著的不同，在handle_edge_irq中，我们仅仅是ack了中断，并没有mask，因为边缘触发的中断稍纵即逝，一旦mask了该中断，容易造成中断丢失。而对于电平中断，我们不得不mask住该中断，如果不mask住，只要CPU ack中断，中断控制器将持续的assert CPU中断(因为有效电平状态一直保持)。如果我们mask住该中断，中断控制器将不再转发该interrupt source来的中断，因此，所有的CPU都不会感知到该中断，直到软件unmask。这里的ack是针对interrupt controller的ack，本身ack就是为了clear interrupt controller对该IRQ的状态寄存器，不过由于外部的电平仍然是有效信号，其实未必能清除interrupt controller的中断状态，不过这是和中断控制器硬件实现相关的。

(2) 对于电平触发的high level handler，我们一开始就mask并ack了中断，因此后续specific handler因该是串行化执行的，为何要判断in progress标记呢?不要忘记spurious interrupt，那里会直接调用handler来处理spurious interrupt。

(3) 这里有两个场景

a、 没有注册specific handler。如果没有注册handler，那么保持mask并设定pending标记(这个pending标记有什么作用还没有想明白)。

b、 该中断被其他的CPU disable了。如果该中断被其他的CPU disable了，本就不应该继续执行该中断的specific handler，我们也是设定pending状态，mask and ack中断就退出了。当其他CPU的代码离开临界区，enable 该中断的时候，软件会检测pending状态并resend该中断。

(4) 为何是有条件的unmask该IRQ?正常的话当然是umask就OK了，不过有些threaded interrupt(这个概念在下一份文档中描述)要求是one shot的(首次中断，specific handler中开了一枪，wakeup了irq handler thread，如果允许中断嵌套，那么在specific handler会多次开枪，这也就不是one shot了，有些IRQ的handler thread要求是one shot，也就是不能嵌套specific handler)。

3、支持EOI的handler

TODO

## (五)：驱动申请中断API

### 一、前言

本文主要的议题是作为一个普通的驱动工程师，在撰写自己负责的驱动的时候，如何向Linux Kernel中的中断子系统注册中断处理函数?

为了理解注册中断的接口，必须了解一些中断线程化(threaded interrupt handler)的基础知识，这些在第二章描述。第三章主要描述了驱动申请 interrupt line接口API request_threaded_irq的规格。第四章是进入request_threaded_irq的实现细节，分析整个代码的执行过程。

### 二、和中断相关的linux实时性分析以及中断线程化的背景介绍

1、非抢占式linux内核的实时性

在遥远的过去，linux2.4之前的内核是不支持抢占特性的，具体可以参考下图：

![](attachment\5.1.gif)

事情的开始源自高优先级任务(橘色block)由于要等待外部事件(例如网络数据)而进入睡眠，调度器调度了某个低优先级的任务(紫色block)执行。该低优先级任务欢畅的执行，直到触发了一次系统调用(例如通过read()文件接口读取磁盘上的文件等)而进入了内核态。仍然是熟悉的配方，仍然是熟悉的味道，低优先级任务正在执行不会变化，只不过从user space切换到了kernel space。外部事件总是在你不想让它来的时候到来，T0时刻，高优先级任务等待的那个中断事件发生了。

中断虽然发生了，但软件不一定立刻响应，可能由于在内核态执行的某些操作不希望被外部事件打断而主动关闭了中断(或是关闭了CPU的中断，或者MASK了该IRQ number)，这时候，中断信号没有立刻得到响应，软件仍然在内核态执行低优先级任务系统调用的代码。在T1时刻，内核态代码由于退出临界区而打开中断(注意：上图中的比例是不协调的，一般而言，linux kernel不会有那么长的关中断时间，上面主要是为了表示清楚，同理，从中断触发到具体中断服务程序的执行也没有那么长，都是为了表述清楚)，中断一旦打开，立刻跳转到了异常向量地址，interrupt handler抢占了低优先级任务的执行，进入中断上下文(虽然这时候的current task是低优先级任务，但是中断上下文和它没有任何关系)。

从CPU开始处理中断到具体中断服务程序被执行还需要一个分发的过程。这个期间系统要做的主要操作包括确定HW interrupt ID，确定IRQ Number，ack或者mask中断，调用中断服务程序等。T0到T2之间的delay被称为中断延迟(Interrupt Latency)，主要包括两部分，一部分是HW造成的delay(硬件的中断系统识别外部的中断事件并signal到CPU)，另外一部分是软件原因(内核代码中由于要保护临界区而关闭中断引起的)。

该中断的服务程序执行完毕(在其执行过程中，T3时刻，会唤醒高优先级任务，让它从sleep状态进入runable状态)，返回低优先级任务的系统调用现场，这时候并不存在一个抢占点，低优先级任务要完成系统调用之后，在返回用户空间的时候才出现抢占点。漫长的等待之后，T4时刻，调度器调度高优先级任务执行。有一个术语叫做任务响应时间(Task Response Time)用来描述T3到T4之间的delay。

2、 抢占式linux内核的实时性

2.6内核和2.4内核显著的不同是提供了一个CONFIG_PREEMPT的选项，打开该选项后，linux kernel就支持了内核代码的抢占(当然不能在临界区)，其行为如下：

![](attachment\5.2.gif)

T0到T3的操作都是和上一节的描述一样的，不同的地方是在T4。对于2.4内核，只有返回用户空间的时候才有抢占点出现，但是对于抢占式内核而言，即便是从中断上下文返回内核空间的进程上下文，只要内核代码不在临界区内，就可以发生调度，让最高优先级的任务调度执行。

在非抢占式linux内核中，一个任务的内核态是不可以被其他进程抢占的。这里并不是说kernel space不可以被抢占，只是说进程通过系统调用陷入到内核的时候，不可以被其他的进程抢占。实际上，中断上下文当然可以抢占进程上下文(无论是内核态还是用户态)，更进一步，中断上下文是拥有至高无上的权限，它甚至可以抢占其他的中断上下文。引入抢占式内核后，系统的平均任务响应时间会缩短，但是，实时性更关注的是：无论在任何的负载情况下，任务响应时间是确定的。因此，更需要关注的是worst-case的任务响应时间。这里有两个因素会影响worst case latency：

(1) 为了同步，内核中总有些代码需要持有自旋锁资源，或者显式的调用preempt_disable来禁止抢占，这时候不允许抢占

(2) 中断上下文(并非只是中断handler，还包括softirq、timer、tasklet)总是可以抢占进程上下文

因此，即便是打开了PREEMPT的选项，实际上linux系统的任务响应时间仍然是不确定的。一方面内核代码的临界区非常多，我们需要找到，系统中持有锁，或者禁止抢占的最大的时间片。另外一方面，在上图的T4中，能顺利的调度高优先级任务并非易事，这时候可能有触发的软中断，也可能有新来的中断，也可能某些driver的tasklet要执行，只有在没有任何bottom half的任务要执行的时候，调度器才会启动调度。

3、 进一步提高linux内核的实时性

通过上一个小节的描述，相信大家都确信中断对linux 实时性的最大的敌人。那么怎么破?我曾经接触过一款RTOS，它的中断handler非常简单，就是发送一个inter-task message到该driver thread，对任何的一个驱动都是如此处理。这样，每个中断上下文都变得非常简短，而且每个中断都是一致的。在这样的设计中，外设中断的处理线程化了，然后，系统设计师要仔细的为每个系统中的task分配优先级，确保整个系统的实时性。

在Linux kernel中，一个外设的中断处理被分成top half和bottom half，top half进行最关键，最基本的处理，而比较耗时的操作被放到bottom half(softirq、tasklet)中延迟执行。虽然bottom half被延迟执行，但始终都是先于进程执行的。为何不让这些耗时的bottom half和普通进程公平竞争呢?因此，linux kernel借鉴了RTOS的某些特性，对那些耗时的驱动interrupt handler进行线程化处理，在内核的抢占点上，让线程(无论是内核线程还是用户空间创建的线程，还是驱动的interrupt thread)在一个舞台上竞争CPU。

### 三、request_threaded_irq的接口规格

1、 输入参数描述

| 输入参数      | 描述                                       |
| --------- | ---------------------------------------- |
| irq       | 要注册handler的那个IRQ number。这里要注册的handler包括两个，一个是传统意义的中断handler，我们称之primary handler，另外一个是threaded interrupt handler |
| handler   | primary handler。需要注意的是primary handler和threaded interrupt handler不能同时为空，否则会出错 |
| thread_fn | threaded interrupt handler。如果该参数不是NULL，那么系统会创建一个kernel thread，调用的function就是thread_fn |
| irqflags  | 参见本章第三节                                  |
| devname   |                                          |
| dev_id    | 参见第四章，第一节中的描述。                           |

2、 输出参数描述

0表示成功执行，负数表示各种错误原因。

3、 Interrupt type flags

| flag定义            | 描述                                       |
| ----------------- | ---------------------------------------- |
| IRQF_TRIGGER_XXX  | 描述该interrupt line触发类型的flag               |
| IRQF_DISABLED     | 首先要说明的是这是一个废弃的flag，在新的内核中，该flag没有任何的作用了。具体可以参考：Disabling IRQF_DISABLED<br>旧的内核(2.6.35版本之前)认为有两种interrupt handler：slow handler和fast handle。在request irq的时候，对于fast handler，需要传递IRQF_DISABLED的参数，确保其中断处理过程中是关闭CPU的中断，因为是fast handler，执行很快，即便是关闭CPU中断不会影响系统的性能。但是，并不是每一种外设中断的handler都是那么快(例如磁盘)，因此就有 slow handler的概念，说明其在中断处理过程中会耗时比较长。对于这种情况，在执行interrupt handler的时候不能关闭CPU中断，否则对系统的performance会有影响。<br>新的内核已经不区分slow handler和fast handle，都是fast handler，都是需要关闭CPU中断的，那些需要后续处理的内容推到threaded interrupt handler中去执行。 |
| IRQF_SHARED       | 这是flag用来描述一个interrupt line是否允许在多个设备中共享。如果中断控制器可以支持足够多的interrupt source，那么在两个外设间共享一个interrupt request line是不推荐的，毕竟有一些额外的开销(发生中断的时候要逐个询问是不是你的中断，软件上就是遍历action list)，因此外设的irq handler中最好是一开始就启动判断，看看是否是自己的中断，如果不是，返回IRQ_NONE,表示这个中断不归我管。 早期PC时代，使用8259中断控制器，级联的8259最多支持15个外部中断，但是PC外设那么多，因此需要irq share。现在，ARM平台上的系统设计很少会采用外设共享IRQ方式，毕竟一般ARM SOC提供的有中断功能的GPIO非常的多，足够用的。 当然，如果确实需要两个外设共享IRQ，那也只能如此设计了。对于HW，中断控制器的一个interrupt source的引脚要接到两个外设的interrupt request line上，怎么接?直接连接可以吗?当然不行，对于低电平触发的情况，我们可以考虑用与门连接中断控制器和外设。 |
| IRQF_PROBE_SHARED | IRQF_SHARED用来表示该interrupt action descriptor是允许和其他device共享一个interrupt line(IRQ number)，但是实际上是否能够share还是需要其他条件：例如触发方式必须相同。有些驱动程序可能有这样的调用场景：我只是想scan一个irq table，看看哪一个是OK的，这时候，如果即便是不能和其他的驱动程序share这个interrupt line，我也没有关系，我就是想scan看看情况。这时候，caller其实可以预见sharing mismatche的发生，因此，不需要内核打印“Flags mismatch irq……“这样冗余的信息 |
| IRQF_PERCPU       | 在SMP的架构下，中断有两种mode，一种中断是在所有processor之间共享的，也就是global的，一旦中断产生，interrupt controller可以把这个中断送达多个处理器。当然，在具体实现的时候不会同时将中断送达多个CPU，一般是软件和硬件协同处理，将中断送达一个CPU处理。但是一段时间内产生的中断可以平均(或者按照既定的策略)分配到一组CPU上。这种interrupt mode下，interrupt controller针对该中断的operational register是global的，所有的CPU看到的都是一套寄存器，一旦一个CPU ack了该中断，那么其他的CPU看到的该interupt source的状态也是已经ack的状态。<br>和global对应的就是per cpu interrupt了，对于这种interrupt，不是processor之间共享的，而是特定属于一个CPU的。例如GIC中interrupt ID等于30的中断就是per cpu的(这个中断event被用于各个CPU的local timer)，这个中断号虽然只有一个，但是，实际上控制该interrupt ID的寄存器有n组(如果系统中有n个processor)，每个CPU看到的是不同的控制寄存器。在具体实现中，这些寄存器组有两种形态，一种是banked，所有CPU操作同样的寄存器地址，硬件系统会根据访问的cpu定向到不同的寄存器，另外一种是non banked，也就是说，对于该interrupt source，每个cpu都有自己独特的访问地址。 |
| IRQF_NOBALANCING  | 这也是和multi-processor相关的一个flag。对于那些可以在多个CPU之间共享的中断，具体送达哪一个processor是有策略的，我们可以在多个CPU之间进行平衡。如果你不想让你的中断参与到irq balancing的过程中那么就设定这个flag |
| IRQF_IRQPOLL      |                                          |
| IRQF_ONESHOT      | one shot本身的意思的只有一次的，结合到中断这个场景，则表示中断是一次性触发的，不能嵌套。对于primary handler，当然是不会嵌套，但是对于threaded interrupt handler，我们有两种选择，一种是mask该interrupt source，另外一种是unmask该interrupt source。一旦mask住该interrupt source，那么该interrupt source的中断在整个threaded interrupt handler处理过程中都是不会再次触发的，也就是one shot了。这种handler不需要考虑重入问题。<br>具体是否要设定one shot的flag是和硬件系统有关的，我们举一个例子，比如电池驱动，电池里面有一个电量计，是使用HDQ协议进行通信的，电池驱动会注册一个threaded interrupt handler，在这个handler中，会通过HDQ协议和电量计进行通信。对于这个handler，通过HDQ进行通信是需要一个完整的HDQ交互过程，如果中间被打断，整个通信过程会出问题，因此，这个handler就必须是one shot的。 |
| IRQF_NO_SUSPEND   | 这个flag比较好理解，就是说在系统suspend的时候，不用disable这个中断，如果disable，可能会导致系统不能正常的resume。 |
| IRQF_FORCE_RESUME | 在系统resume的过程中，强制必须进行enable的动作，即便是设定了IRQF_NO_SUSPEND这个flag。这是和特定的硬件行为相关的。 |
| IRQF_NO_THREAD    | 有些low level的interrupt是不能线程化的(例如系统timer的中断)，这个flag就是起这个作用的。另外，有些级联的interrupt controller对应的IRQ也是不能线程化的(例如secondary GIC对应的IRQ)，它的线程化可能会影响一大批附属于该interrupt controller的外设的中断响应延迟。 |
| IRQF_EARLY_RESUME |                                          |
| IRQF_TIMER        |                                          |

### 四、request_threaded_irq代码分析

1、 request_threaded_irq主流程

```c
int request_threaded_irq(unsigned int irq, irq_handler_t handler,
irq_handler_t thread_fn, unsigned long irqflags,
const char *devname, void *dev_id)
{
    if ((irqflags & IRQF_SHARED) && !dev_id)－－－－－－－－－(1)
        return -EINVAL;
    desc = irq_to_desc(irq); －－－－－－－－－－－－－－－－－(2)
    if (!desc)         return -EINVAL;
        if (!irq_settings_can_request(desc) || －－－－－－－－－－－－(3)
            WARN_ON(irq_settings_is_per_cpu_devid(desc)))
            return -EINVAL;
    if (!handler) { －－－－－－－－－－－－－－－－－－－－－－(4)
        if (!thread_fn)
            return -EINVAL;
        handler = irq_default_primary_handler;
    }
    action = kzalloc(sizeof(struct irqaction), GFP_KERNEL);
    action->handler = handler;
    action->thread_fn = thread_fn;
    action->flags = irqflags;
    action->name = devname;
    action->dev_id = dev_id;
    chip_bus_lock(desc);
    retval = __setup_irq(irq, desc, action); －－－－－－－－－－－(5)
    chip_bus_sync_unlock(desc);
}
```

(1) 对于那些需要共享的中断，在request irq的时候需要给出dev id，否则会出错退出。为何对于IRQF_SHARED的中断必须要给出dev id呢?实际上，在共享的情况下，一个IRQ number对应若干个irqaction，当操作irqaction的时候，仅仅给出IRQ number就不是非常的足够了，这时候，需要一个ID表示具体的irqaction，这里就是dev_id的作用了。我们举一个例子：

void free_irq(unsigned int irq, void *dev_id)

当释放一个IRQ资源的时候，不但要给出IRQ number，还要给出device ID。只有这样，才能精准的把要释放的那个irqaction 从irq action list上移除。dev_id在中断处理中有没有作用呢?我们来看看source code：

```c
irqreturn_t handle_irq_event_percpu(struct irq_desc *desc, struct irqaction *action)
{
    do {
        irqreturn_t res;
        res = action->handler(irq, action->dev_id);
        ……
        action = action->next;
    } while (action);
    ……
}
```

linux interrupt framework虽然支持中断共享，但是它并不会协助解决识别问题，它只会遍历该IRQ number上注册的irqaction的callback函数，这样，虽然只是一个外设产生的中断，linux kernel还是把所有共享的那些中断handler都逐个调用执行。为了让系统的performance不受影响，irqaction的callback函数必须在函数的最开始进行判断，是否是自己的硬件设备产生了中断(读取硬件的寄存器)，如果不是，尽快的退出。

需要注意的是，这里dev_id并不能在中断触发的时候用来标识需要调用哪一个irqaction的callback函数，通过上面的代码也可以看出，dev_id有些类似一个参数传递的过程，可以把具体driver的一些硬件信息，组合成一个structure，在触发中断的时候可以把这个structure传递给中断处理函数。

(2) 通过IRQ number获取对应的中断描述符。在引入CONFIG_SPARSE_IRQ选项后，这个转换变得不是那么简单了。在过去，我们会以IRQ number为index，从irq_desc这个全局数组中直接获取中断描述符。如果配置CONFIG_SPARSE_IRQ选项，则需要从radix tree中搜索。CONFIG_SPARSE_IRQ选项的更详细的介绍请参考IRQ number和中断描述符

(3) 并非系统中所有的IRQ number都可以request，有些中断描述符被标记为IRQ_NOREQUEST，标识该IRQ number不能被其他的驱动request。一般而言，这些IRQ number有特殊的作用，例如用于级联的那个IRQ number是不能request。irq_settings_can_request函数就是判断一个IRQ是否可以被request。

irq_settings_is_per_cpu_devid函数用来判断一个中断描述符是否需要传递per cpu的device ID。per cpu的中断上面已经描述的很清楚了，这里不再细述。如果一个中断描述符对应的中断 ID是per cpu的，那么在申请其handler的时候就有两种情况，一种是传递统一的dev_id参数(传入request_threaded_irq的最后一个参数)，另外一种情况是针对每个CPU，传递不同的dev_id参数。在这种情况下，我们需要调用request_percpu_irq接口函数而不是request_threaded_irq。

(4) 传入request_threaded_irq的primary handler和threaded handler参数有下面四种组合：

| primary handler | threaded handler | 描述                                       |
| --------------- | ---------------- | ---------------------------------------- |
| NULL            | NULL             | 函数出错，返回-EINVAL                           |
| 设定              | 设定               | 正常流程。中断处理被合理的分配到primary handler和threaded handler中。 |
| 设定              | NULL             | 中断处理都是在primary handler中完成                |
| NULL            | 设定               | 这种情况下，系统会帮忙设定一个default的primary handler：irq_default_primary_handler，协助唤醒threaded handler线程 |

(5) 这部分的代码很简单，分配struct irqaction，赋值，调用__setup_irq进行实际的注册过程。这里要罗嗦几句的是锁的操作，在内核中，有很多函数，有的是需要调用者自己加锁保护的，有些是不需要加锁保护的。对于这些场景，linux kernel采取了统一的策略：基本函数名字是一样的，只不过需要调用者自己加锁保护的那个函数需要增加__的前缀，例如内核有有下面两个函数：setup_irq和__setup_irq。这里，我们在setup irq的时候已经调用chip_bus_lock进行保护，因此使用lock free的版本__setup_irq。

chip_bus_lock定义如下：

```c
static inline void chip_bus_lock(struct irq_desc *desc)
{
    if (unlikely(desc->irq_data.chip->irq_bus_lock))
    desc->irq_data.chip->irq_bus_lock(&desc->irq_data);
}
```

大部分的interrupt controller并没有定义irq_bus_lock这个callback函数，因此chip_bus_lock这个函数对大多数的中断控制器而言是没有实际意义的。但是，有些interrupt controller是连接到慢速总线上的，例如一个i2c接口的IO expander芯片(这种芯片往往也提供若干有中断功能的GPIO，因此也是一个interrupt controller)，在访问这种interrupt controller的时候需要lock住那个慢速bus(只能有一个client在使用I2C bus)。

2、 注册irqaction

(1) nested IRQ的处理代码

在看具体的代码之前，我们首先要理解什么是nested IRQ。nested IRQ不是cascade IRQ，在GIC代码分析中我们有描述过cascade IRQ这个概念，主要用在interrupt controller级联的情况下。为了方便大家理解，我还是给出一个具体的例子吧，具体的HW block请参考下图：

![](attachment\5.3.gif)

上图是一个两个GIC级联的例子，所有的HW block封装在了一个SOC chip中。为了方便描述，我们先进行编号：Secondary GIC的IRQ number是A，外设1的IRQ number是B，外设2的IRQ number是C。对于上面的硬件，linux kernel处理如下：

(a) IRQ A的中断描述符被设定为不能注册irqaction(不能注册specific interrupt handler，或者叫中断服务程序)

(b) IRQ A的highlevel irq-events handler(处理interrupt flow control)负责进行IRQ number的映射，在其irq domain上翻译出具体外设的IRQ number，并重新定向到外设IRQ number对应的highlevel irq-events handler。

(c) 所有外设驱动的中断正常request irq，可以任意选择线程化的handler，或者只注册primary handler。

需要注意的是，对root GIC和Secondary GIC寄存器的访问非常快，因此ack、mask、EOI等操作也非常快。

我们再看看另外一个interrupt controller级联的情况：

![](attachment\5.4.gif)

IO expander HW block提供了有中断功能的GPIO，因此它也是一个interrupt controller，有它自己的irq domain和irq chip。上图中外设1和外设2使用了IO expander上有中断功能的GPIO，它们有属于自己的IRQ number以及中断描述符。IO expander HW block的IRQ line连接到SOC内部的interrupt controller上，因此，这也是一个interrupt controller级联的情况，对于这种情况，我们是否可以采用和上面GIC级联的处理方式呢?

不行，对于GIC级联的情况，如果secondary GIC上的外设1产生了中断，整个关中断的时间是IRQ A的中断描述符的highlevel irq-events handler处理时间+IRQ B的的中断描述符的highlevel irq-events handler处理时间+外设1的primary handler的处理时间。所幸对root GIC和Secondary GIC寄存器的访问非常快，因此整个关中断的时间也不是非常的长。但是如果是IO expander这个情况，如果采取和上面GIC级联的处理方式一样的话，关中断的时间非常长。我们还是用外设1产生的中断为例子好了。这时候，由于IRQ B的的中断描述符的highlevel irq-events handler处理设计I2C的操作，因此时间非常的长，这时候，对于整个系统的实时性而言是致命的打击。对这种硬件情况，linux kernel处理如下：

(a) IRQ A的中断描述符的highlevel irq-events handler根据实际情况进行设定，并且允许注册irqaction。对于连接到IO expander上的外设，它是没有real time的要求的(否则也不会接到IO expander上)，因此一般会进行线程化处理。由于threaded handler中涉及I2C操作，因此要设定IRQF_ONESHOT的flag。

(b) 在IRQ A的中断描述符的threaded interrupt handler中进行进行IRQ number的映射，在IO expander irq domain上翻译出具体外设的IRQ number，并直接调用handle_nested_irq函数处理该IRQ。

(c) 外设对应的中断描述符设定IRQ_NESTED_THREAD的flag，表明这是一个nested IRQ。nested IRQ没有highlevel irq-events handler，也没有primary handler，它的threaded interrupt handler是附着在其parent IRQ的threaded handler上的。

具体的nested IRQ的处理代码如下：

```c
static int __setup_irq(unsigned int irq, struct irq_desc *desc, struct irqaction *new)
{
    ……
    nested = irq_settings_is_nested_thread(desc);
    if (nested) {
        if (!new->thread_fn) {
            ret = -EINVAL;
            goto out_mput;
        }
        new->handler = irq_nested_primary_handler;
    } else {
        ……
    }
    ……
}
```

如果一个中断描述符是nested thread type的，说明这个中断描述符应该设定threaded interrupt handler(当然，内核是不会单独创建一个thread的，它是借着其parent IRQ的interrupt thread执行)，否则就会出错返回。对于primary handler，它应该没有机会被调用到，当然为了调试，kernel将其设定为irq_nested_primary_handler，以便在调用的时候打印一些信息，让工程师直到发生了什么状况。

(2) forced irq threading处理

具体的forced irq threading的处理代码如下：

```c
static int __setup_irq(unsigned int irq, struct irq_desc *desc, struct irqaction *new)
{
    ……
    nested = irq_settings_is_nested_thread(desc);
    if (nested) {
        ……
    } else {
        if (irq_settings_can_thread(desc))
        irq_setup_forced_threading(new);
    }
    ……
}
```

forced irq threading其实就是将系统中所有可以被线程化的中断handler全部线程化，即便你在request irq的时候，设定的是primary handler，而不是threaded handler。当然那些不能被线程化的中断(标注了IRQF_NO_THREAD的中断，例如系统timer)还是排除在外的。irq_settings_can_thread函数就是判断一个中断是否可以被线程化，如果可以的话，则调用irq_setup_forced_threading在set irq的时候强制进行线程化。具体代码如下：

```c
static void irq_setup_forced_threading(struct irqaction *new)
{
    if (!force_irqthreads)－－－－－－－－－－－－－－－－－－－－－－－－－－－－－－－(a)
        return;
    if (new->flags & (IRQF_NO_THREAD | IRQF_PERCPU | IRQF_ONESHOT))－－－－－－－(b)
        return;
    new->flags |= IRQF_ONESHOT; －－－－－－－－－－－－－－－－－－－－－－－－－(d)
    if (!new->thread_fn) {－－－－－－－－－－－－－－－－－－－－－－－－－－－－－－－(c)
        set_bit(IRQTF_FORCED_THREAD, &new->thread_flags);
        new->thread_fn = new->handler;
        new->handler = irq_default_primary_handler;
    }
}
```

(a) 系统中有一个强制线程化的选项：CONFIG_IRQ_FORCED_THREADING，如果没有打开该选项，force_irqthreads总是0，因此irq_setup_forced_threading也就没有什么作用，直接return了。如果打开了CONFIG_IRQ_FORCED_THREADING，说明系统支持强制线程化，但是具体是否对所有的中断进行强制线程化处理还是要看命令行参数threadirqs。如果kernel启动的时候没有传入该参数，那么同样的，irq_setup_forced_threading也就没有什么作用，直接return了。只有bootloader向内核传入threadirqs这个命令行参数，内核才真正在启动过程中，进行各个中断的强制线程化的操作。

(b) 看到IRQF_NO_THREAD选项你可能会奇怪，前面irq_settings_can_thread函数不是检查过了吗?为何还要重复检查?其实一个中断是否可以进行线程化可以从两个层面看：一个是从底层看，也就是从中断描述符、从实际的中断硬件拓扑等方面看。另外一个是从中断子系统的用户层面看，也就是各个外设在注册自己的handler的时候是否想进行线程化处理。所有的IRQF_XXX都是从用户层面看的flag，因此如果用户通过IRQF_NO_THREAD这个flag告知kernel，该interrupt不能被线程化，那么强制线程化的机制还是尊重用户的选择的。

PER CPU的中断都是一些较为特殊的中断，不是一般意义上的外设中断，因此对PER CPU的中断不强制进行线程化。IRQF_ONESHOT选项说明该中断已经被线程化了(而且是特殊的one shot类型的)，因此也是直接返回了。

(c) 强制线程化只对那些没有设定thread_fn的中断进行处理，这种中断将全部的处理放在了primary interrupt handler中(当然，如果中断处理比较耗时，那么也可能会采用bottom half的机制)，由于primary interrupt handler是全程关闭CPU中断的，因此可能对系统的实时性造成影响，因此考虑将其强制线程化。struct irqaction中的thread_flags是和线程相关的flag，我们给它打上IRQTF_FORCED_THREAD的标签，表明该threaded handler是被强制threaded的。new->thread_fn = new->handler这段代码表示将原来primary handler中的内容全部放到threaded handler中处理，新的primary handler被设定为default handler。

(d) 强制线程化是一个和实时性相关的选项，从我的角度来看是一个很不好的设计(个人观点)，各个驱动工程师在撰写自己的驱动代码的时候已经安排好了自己的上下文环境。有的是进程上下文，有的是中断上下文，在各自的上下文环境中，驱动工程师又选择了适合的内核同步机制。但是，强制线程化导致原来运行在中断上下文的primary handler现在运行在进程上下文，这有可能导致一些难以跟踪和定位的bug。

当然，作为内核的开发者，既然同意将强制线程化这个特性并入linux kernel，相信他们有他们自己的考虑。我猜测这是和一些旧的驱动代码维护相关的。linux kernel中的中断子系统的API的修改会引起非常大的震动，因为内核中成千上万的驱动都是需要调用旧的接口来申请linux kernel中断子系统的服务，对每一个驱动都进行修改是一个非常耗时的工作，为了让那些旧的驱动代码可以运行在新的中断子系统上，因此，在kernel中，实际上仍然提供了旧的request_irq接口函数，如下：

```c
static inline int __must_check
request_irq(unsigned int irq, irq_handler_t handler, unsigned long flags,
const char *name, void *dev)
{
    return request_threaded_irq(irq, handler, NULL, flags, name, dev);
}
```

接口是OK了，但是，新的中断子系统的思路是将中断处理分成primary handler和threaded handler，而旧的驱动代码一般是将中断处理分成top half和bottom half，如何将这部分的不同抹平?linux kernel是这样处理的(这是我个人的理解，不保证是正确的)：

(d-1)内核为那些被强制线程化的中断handler设定了IRQF_ONESHOT的标识。这是因为在旧的中断处理机制中，top half是不可重入的，强制线程化之后，强制设定IRQF_ONESHOT可以保证threaded handler是不会重入的。

(d-2)在那些被强制线程化的中断线程中，disable bottom half的处理。这是因为在旧的中断处理机制中，botton half是不可能抢占top half的执行，强制线程化之后，应该保持这一点。

(3) 创建interrupt线程。代码如下：

```c
if (new->thread_fn && !nested) {
struct task_struct *t;
static const struct sched_param param = {
.sched_priority = MAX_USER_RT_PRIO/2,
};
t = kthread_create(irq_thread, new, "irq/%d-%s", irq,－－－－－－－－－－－－－－－－－－(a)
new->name);
sched_setscheduler_nocheck(t, SCHED_FIFO, ¶m);
get_task_struct(t);－－－－－－－－－－－－－－－－－－－－－－－－－－－(b)
new->thread = t;
set_bit(IRQTF_AFFINITY, &new->thread_flags);－－－－－－－－－－－－－－－(c)
}
if (!alloc_cpumask_var(&mask, GFP_KERNEL)) {－－－－－－－－－－－－－－－－(d)
ret = -ENOMEM;
goto out_thread;
}
if (desc->irq_data.chip->flags & IRQCHIP_ONESHOT_SAFE)－－－－－－－－－－－(e)
new->flags &= ~IRQF_ONESHOT;
```

(a) 调用kthread_create来创建一个内核线程，并调用sched_setscheduler_nocheck来设定这个中断线程的调度策略和调度优先级。这些是和进程管理相关的内容，我们留到下一个专题再详细描述吧。

(b) 调用get_task_struct可以为这个threaded handler的task struct增加一次reference count，这样，即便是该thread异常退出也可以保证它的task struct不会被释放掉。这可以保证中断系统的代码不会访问到一些被释放的内存。irqaction的thread 成员被设定为刚刚创建的task，这样，primary handler就知道唤醒哪一个中断线程了。

(c) 设定IRQTF_AFFINITY的标志，在threaded handler中会检查该标志并进行IRQ affinity的设定。

(d) 分配一个cpu mask的变量的内存，后面会使用到

(e) 驱动工程师是撰写具体外设驱动的，他/她未必会了解到底层的一些具体的interrupt controller的信息。有些interrupt controller(例如MSI based interrupt)本质上就是就是one shot的(通过IRQCHIP_ONESHOT_SAFE标记)，因此驱动工程师设定的IRQF_ONESHOT其实是画蛇添足，因此可以去掉。

(4) 共享中断的检查。代码如下：

```c
old_ptr = &desc->action;

old = *old_ptr;

if (old) {

if (!((old->flags & new->flags) & IRQF_SHARED) ||－－－－－－－－－－－－－－－－－(a)

((old->flags ^ new->flags) & IRQF_TRIGGER_MASK) ||

((old->flags ^ new->flags) & IRQF_ONESHOT))

goto mismatch;

/* All handlers must agree on per-cpuness */

if ((old->flags & IRQF_PERCPU) != (new->flags & IRQF_PERCPU))

goto mismatch;

/* add new interrupt at end of irq queue */

do {－－－－－－－－－－－－－－－－－－－－－－－－－－－－－－－－－－－－(b)

thread_mask |= old->thread_mask;

old_ptr = &old->next;

old = *old_ptr;

} while (old);

shared = 1;

}
```

(a) old指向注册之前的action list，如果不是NULL，那么说明需要共享interrupt line。但是如果要共享，需要每一个irqaction都同意共享(IRQF_SHARED)，每一个irqaction的触发方式相同(都是level trigger或者都是edge trigger)，相同的oneshot类型的中断(都是one shot或者都不是)，per cpu类型的相同中断(都是per cpu的中断或者都不是)。

(b) 将该irqaction挂入队列的尾部。

(5) thread mask的设定。代码如下：

```c
if (new->flags & IRQF_ONESHOT) {
    if (thread_mask == ~0UL) {－－－－－－－－－－－－－－－－－－－－－－－－(a)
        ret = -EBUSY;
        goto out_mask;
    }
    new->thread_mask = 1 << ffz(thread_mask);
} else if (new->handler == irq_default_primary_handler &&
!(desc->irq_data.chip->flags & IRQCHIP_ONESHOT_SAFE)) {－－－－－－－－(b)
    ret = -EINVAL;
    goto out_mask;
}
```

对于one shot类型的中断，我们还需要设定thread mask。如果一个one shot类型的中断只有一个threaded handler(不支持共享)，那么事情就很简单(临时变量thread_mask等于0)，该irqaction的thread_mask成员总是使用第一个bit来标识该irqaction。但是，如果支持共享的话，事情变得有点复杂。我们假设这个one shot类型的IRQ上有A，B和C三个irqaction，那么A，B和C三个irqaction的thread_mask成员会有不同的bit来标识自己。例如A的thread_mask成员是0x01，B的是0x02，C的是0x04，如果有更多共享的irqaction(必须是oneshot类型)，那么其thread_mask成员会依次设定为0x08，0x10……

(a) 在上面“共享中断的检查”这个section中，thread_mask变量保存了所有的属于该interrupt line的thread_mask，这时候，如果thread_mask变量如果是全1，那么说明irqaction list上已经有了太多的irq action(大于32或者64，和具体系统和编译器相关)。如果没有满，那么通过ffz函数找到第一个为0的bit作为该irq action的thread bit mask。

(b) irq_default_primary_handler的代码如下：

```c
static irqreturn_t irq_default_primary_handler(int irq, void *dev_id)
{
    return IRQ_WAKE_THREAD;
}
```

代码非常的简单，返回IRQ_WAKE_THREAD，让kernel唤醒threaded handler就OK了。使用irq_default_primary_handler虽然简单，但是有一个风险：如果是电平触发的中断，我们需要操作外设的寄存器才可以让那个asserted的电平信号消失，否则它会一直持续。一般，我们都是直接在primary中操作外设寄存器(slow bus类型的interrupt controller不行)，尽早的clear interrupt，但是，对于irq_default_primary_handler，它仅仅是wakeup了threaded interrupt handler，并没有clear interrupt，这样，执行完了primary handler，外设中断仍然是asserted，一旦打开CPU中断，立刻触发下一次的中断，然后不断的循环。因此，如果注册中断的时候没有指定primary interrupt handler，并且没有设定IRQF_ONESHOT，那么系统是会报错的。当然，有一种情况可以豁免，当底层的irq chip是one shot safe的(IRQCHIP_ONESHOT_SAFE)。

(6) 用户IRQ flag和底层interrupt flag的同步(TODO)

## (六)：ARM中断处理过程

### 一、前言

本文主要以ARM体系结构下的中断处理为例，讲述整个中断处理过程中的硬件行为和软件动作。具体整个处理过程分成三个步骤来描述：

1、第二章描述了中断处理的准备过程

2、第三章描述了当发生中的时候，ARM硬件的行为

3、第四章描述了ARM的中断进入过程

4、第五章描述了ARM的中断退出过程

本文涉及的代码来自3.14内核。另外，本文注意描述ARM指令集的内容，有些source code为了简短一些，删除了THUMB相关的代码，除此之外，有些debug相关的内容也会删除。

### 二、中断处理的准备过程

1、中断模式的stack准备

ARM处理器有多种processor mode，例如user mode(用户空间的AP所处于的模式)、supervisor mode(即SVC mode，大部分的内核态代码都处于这种mode)、IRQ mode(发生中断后，处理器会切入到该mode)等。对于linux kernel，其中断处理处理过程中，ARM 处理器大部分都是处于SVC mode。但是，实际上产生中断的时候，ARM处理器实际上是进入IRQ mode，因此在进入真正的IRQ异常处理之前会有一小段IRQ mode的操作，之后会进入SVC mode进行真正的IRQ异常处理。由于IRQ mode只是一个过度，因此IRQ mode的栈很小，只有12个字节，具体如下：

```c
struct stack {
    u32 irq[3];
    u32 abt[3];
    u32 und[3];
} ____cacheline_aligned;
static struct stack stacks[NR_CPUS];
```

除了irq mode，linux kernel在处理abt mode(当发生data abort exception或者prefetch abort exception的时候进入的模式)和und mode(处理器遇到一个未定义的指令的时候进入的异常模式)的时候也是采用了相同的策略。也就是经过一个简短的abt或者und mode之后，stack切换到svc mode的栈上，这个栈就是发生异常那个时间点current thread的内核栈。anyway，在irq mode和svc mode之间总是需要一个stack保存数据，这就是中断模式的stack，系统初始化的时候，cpu_init函数中会进行中断模式stack的设定：

```c
void notrace cpu_init(void)
{
    unsigned int cpu = smp_processor_id();－－－－－－获取CPU ID
    struct stack *stk = &stacks[cpu];－－－－－－－－－获取该CPU对于的irq abt和und的stack指针
    ……
#ifdef CONFIG_THUMB2_KERNEL
#define PLC    "r"－－－－－－Thumb-2下，msr指令不允许使用立即数，只能使用寄存器。
#else
#define PLC    "I"
#endif
    __asm__ (
        "msr    cpsr_c, %1\n\t"－－－－－－让CPU进入IRQ mode
        "add    r14, %0, %2\n\t"－－－－－－r14寄存器保存stk->irq
        "mov    sp, r14\n\t"－－－－－－－－设定IRQ mode的stack为stk->irq
        "msr    cpsr_c, %3\n\t"
        "add    r14, %0, %4\n\t"
        "mov    sp, r14\n\t"－－－－－－－－设定abt mode的stack为stk->abt
        "msr    cpsr_c, %5\n\t"
        "add    r14, %0, %6\n\t"
        "mov    sp, r14\n\t"－－－－－－－－设定und mode的stack为stk->und
        "msr    cpsr_c, %7"－－－－－－－－回到SVC mode
        :－－－－－－－－－－－－－－－－－－－－上面是code，下面的output部分是空的
        : "r" (stk),－－－－－－－－－－－－－－－－－－－－－－对应上面代码中的%0
        PLC (PSR_F_BIT | PSR_I_BIT | IRQ_MODE),－－－－－－对应上面代码中的%1
        "I" (offsetof(struct stack, irq[0])),－－－－－－－－－－－－对应上面代码中的%2
        PLC (PSR_F_BIT | PSR_I_BIT | ABT_MODE),－－－－－－以此类推，下面不赘述
        "I" (offsetof(struct stack, abt[0])),
        PLC (PSR_F_BIT | PSR_I_BIT | UND_MODE),
        "I" (offsetof(struct stack, und[0])),
        PLC (PSR_F_BIT | PSR_I_BIT | SVC_MODE)
        : "r14");－－－－－－－－上面是input操作数列表，r14是要clobbered register列表
}
```

嵌入式汇编的语法格式是：asm(code : output operand list : input operand list : clobber list);大家对着上面的code就可以分开各段内容了。在input operand list中，有两种限制符(constraint)，"r"或者"I"，"I"表示立即数(Immediate operands)，"r"表示用通用寄存器传递参数。clobber list中有一个r14，表示在汇编代码中修改了r14的值，这些信息是编译器需要的内容。

对于SMP，bootstrap CPU会在系统初始化的时候执行cpu_init函数，进行本CPU的irq、abt和und三种模式的内核栈的设定，具体调用序列是：start_kernel--->setup_arch--->setup_processor--->cpu_init。对于系统中其他的CPU，bootstrap CPU会在系统初始化的最后，对每一个online的CPU进行初始化，具体的调用序列是：start_kernel--->rest_init--->kernel_init--->kernel_init_freeable--->kernel_init_freeable--->smp_init--->cpu_up--->_cpu_up--->__cpu_up。__cpu_up函数是和CPU architecture相关的。对于ARM，其调用序列是__cpu_up--->boot_secondary--->smp_ops.smp_boot_secondary(SOC相关代码)--->secondary_startup--->__secondary_switched--->secondary_start_kernel--->cpu_init。

除了初始化，系统电源管理也需要irq、abt和und stack的设定。如果我们设定的电源管理状态在进入sleep的时候，CPU会丢失irq、abt和und stack point寄存器的值，那么在CPU resume的过程中，要调用cpu_init来重新设定这些值。

2、 SVC模式的stack准备

我们经常说进程的用户空间和内核空间，对于一个应用程序而言，可以运行在用户空间，也可以通过系统调用进入内核空间。在用户空间，使用的是用户栈，也就是我们软件工程师编写用户空间程序的时候，保存局部变量的stack。陷入内核后，当然不能用用户栈了，这时候就需要使用到内核栈。所谓内核栈其实就是处于SVC mode时候使用的栈。

在linux最开始启动的时候，系统只有一个进程(更准确的说是kernel thread)，就是PID等于0的那个进程，叫做swapper进程(或者叫做idle进程)。该进程的内核栈是静态定义的，如下：

```c
union thread_union init_thread_union __init_task_data =
    { INIT_THREAD_INFO(init_task) };
union thread_union {
    struct thread_info thread_info;
    unsigned long stack[THREAD_SIZE/sizeof(long)];
};
```

对于ARM平台，THREAD_SIZE是8192个byte，因此占据两个page frame。随着初始化的进行，Linux kernel会创建若干的内核线程，而在进入用户空间后，user space的进程也会创建进程或者线程。Linux kernel在创建进程(包括用户进程和内核线程)的时候都会分配一个(或者两个，和配置相关)page frame，具体代码如下：

```c
static struct task_struct *dup_task_struct(struct task_struct *orig)
{
    ......
    ti = alloc_thread_info_node(tsk, node);
    if (!ti)
        goto free_tsk;
    ......
}
```

底部是struct thread_info数据结构，顶部(高地址)就是该进程的内核栈。当进程切换的时候，整个硬件和软件的上下文都会进行切换，这里就包括了svc mode的sp寄存器的值被切换到调度算法选定的新的进程的内核栈上来。

3、 异常向量表的准备

对于ARM处理器而言，当发生异常的时候，处理器会暂停当前指令的执行，保存现场，转而去执行对应的异常向量处的指令，当处理完该异常的时候，恢复现场，回到原来的那点去继续执行程序。系统所有的异常向量(共计8个)组成了异常向量表。向量表(vector table)的代码如下：

```assembly
.section .vectors, "ax", %progbits
__vectors_start:
    W(b)    vector_rst
    W(b)    vector_und
    W(ldr)    pc, __vectors_start + 0x1000
    W(b)    vector_pabt
    W(b)    vector_dabt
    W(b)    vector_addrexcptn
    W(b)    vector_irq ---------------------------IRQ Vector
    W(b)    vector_fiq
```
对于本文而言，我们重点关注vector_irq这个exception vector。异常向量表可能被安放在两个位置上：

(1) 异常向量表位于0x0的地址。这种设置叫做Normal vectors或者Low vectors。

(2) 异常向量表位于0xffff0000的地址。这种设置叫做high vectors

具体是low vectors还是high vectors是由ARM的一个叫做的SCTLR寄存器的第13个bit (vector bit)控制的。对于启用MMU的ARM Linux而言，系统使用了high vectors。为什么不用low vector呢?对于linux而言，0~3G的空间是用户空间，如果使用low vector，那么异常向量表在0地址，那么则是用户空间的位置，因此linux选用high vector。当然，使用Low vector也可以，这样Low vector所在的空间则属于kernel space了(也就是说，3G~4G的空间加上Low vector所占的空间属于kernel space)，不过这时候要注意一点，因为所有的进程共享kernel space，而用户空间的程序经常会发生空指针访问，这时候，内存保护机制应该可以捕获这种错误(大部分的MMU都可以做到，例如：禁止userspace访问kernel space的地址空间)，防止vector table被访问到。对于内核中由于程序错误导致的空指针访问，内存保护机制也需要控制vector table被修改，因此vector table所在的空间被设置成read only的。在使用了MMU之后，具体异常向量表放在那个物理地址已经不重要了，重要的是把它映射到0xffff0000的虚拟地址就OK了，具体代码如下：

```c
static void __init devicemaps_init(const struct machine_desc *mdesc)
{
    ……
    vectors = early_alloc(PAGE_SIZE * 2); －－－－－分配两个page的物理页帧
    early_trap_init(vectors); －－－－－－－copy向量表以及相关help function到该区域
    ……
    map.pfn = __phys_to_pfn(virt_to_phys(vectors));
    map.virtual = 0xffff0000;
    map.length = PAGE_SIZE;
#ifdef CONFIG_KUSER_HELPERS
    map.type = MT_HIGH_VECTORS;
#else
    map.type = MT_LOW_VECTORS;
#endif
    create_mapping(&map); －－－－－－－－－－映射0xffff0000的那个page frame
    if (!vectors_high()) {－－－如果SCTLR.V的值设定为low vectors，那么还要映射0地址开始的memory
        map.virtual = 0;
        map.length = PAGE_SIZE * 2;
        map.type = MT_LOW_VECTORS;
        create_mapping(&map);
    }
    map.pfn += 1;
    map.virtual = 0xffff0000 + PAGE_SIZE;
    map.length = PAGE_SIZE;
    map.type = MT_LOW_VECTORS;
    create_mapping(&map); －－－－－－－－－－映射high vecotr开始的第二个page frame
    ……
}
```

为什么要分配两个page frame呢?这里vectors table和kuser helper函数(内核空间提供的函数，但是用户空间使用)占用了一个page frame，另外异常处理的stub函数占用了另外一个page frame。为什么会有stub函数呢?稍后会讲到。

在early_trap_init函数中会初始化异常向量表，具体代码如下：

```c
void __init early_trap_init(void *vectors_base)
{
    unsigned long vectors = (unsigned long)vectors_base;
    extern char __stubs_start[], __stubs_end[];
    extern char __vectors_start[], __vectors_end[];
    unsigned i;
    vectors_page = vectors_base;
    将整个vector table那个page frame填充成未定义的指令。起始vector table加上kuser helper函数并不能完全的充满这个page，有些缝隙。如果不这么处理，当极端情况下(程序错误或者HW的issue)，CPU可能从这些缝隙中取指执行，从而导致不可知的后果。如果将这些缝隙填充未定义指令，那么CPU可以捕获这种异常。
    for (i = 0; i < PAGE_SIZE / sizeof(u32); i++)
    ((u32 *)vectors_base)[i] = 0xe7fddef1;
    拷贝vector table，拷贝stub function
    memcpy((void *)vectors, __vectors_start, __vectors_end - __vectors_start);
    memcpy((void *)vectors + 0x1000, __stubs_start, __stubs_end - __stubs_start);
    kuser_init(vectors_base); －－－－copy kuser helper function
    flush_icache_range(vectors, vectors + PAGE_SIZE * 2);
    modify_domain(DOMAIN_USER, DOMAIN_CLIENT);
}
```

一旦涉及代码的拷贝，我们就需要关心其编译连接时地址(link-time address)和运行时地址(run-time address)。在kernel完成链接后，__vectors_start有了其link-time address，如果link-time address和run-time address一致，那么这段代码运行时毫无压力。但是，目前对于vector table而言，其被copy到其他的地址上(对于High vector，这是地址就是0xffff00000)，也就是说，link-time address和run-time address不一样了，如果仍然想要这些代码可以正确运行，那么需要这些代码是位置无关的代码。对于vector table而言，必须要位置无关。B这个branch instruction本身就是位置无关的，它可以跳转到一个当前位置的offset。不过并非所有的vector都是使用了branch instruction，对于软中断，其vector地址上指令是“W(ldr)    pc, __vectors_start + 0x1000 ”，这条指令被编译器编译成ldr     pc, [pc, #4080]，这种情况下，该指令也是位置无关的，但是有个限制，offset必须在4K的范围内，这也是为何存在stub section的原因了。

4、 中断控制器的初始化

具体可以参考GIC代码分析。

### 三、ARM HW对中断事件的处理

当一切准备好之后，一旦打开处理器的全局中断就可以处理来自外设的各种中断事件了。

当外设(SOC内部或者外部都可以)检测到了中断事件，就会通过interrupt requestion line上的电平或者边沿(上升沿或者下降沿或者both)通知到该外设连接到的那个中断控制器，而中断控制器就会在多个处理器中选择一个，并把该中断通过IRQ(或者FIQ，本文不讨论FIQ的情况)分发给该processor。ARM处理器感知到了中断事件后，会进行下面一系列的动作：

1、 修改CPSR(Current Program Status Register)寄存器中的M[4:0]。M[4:0]表示了ARM处理器当前处于的模式( processor modes)。ARM定义的mode包括：


| 处理器模式      | 缩写   | 对应的M[4:0]编码 | Privilege level |
| ---------- | ---- | ----------- | --------------- |
| User       | usr  | 10000       | PL0             |
| FIQ        | fiq  | 10001       | PL1             |
| IRQ        | irq  | 10010       | PL1             |
| Supervisor | svc  | 10011       | PL1             |
| Monitor    | mon  | 10110       | PL1             |
| Abort      | abt  | 10111       | PL1             |
| Hyp        | hyp  | 11010       | PL2             |
| Undefined  | und  | 11011       | PL1             |
| System     | sys  | 11111       | PL1             |

一旦设定了CPSR.M，ARM处理器就会将processor mode切换到IRQ mode。

2、 保存发生中断那一点的CPSR值(step 1之前的状态)和PC值

ARM处理器支持9种processor mode，每种mode看到的ARM core register(R0~R15，共计16个)都是不同的。每种mode都是从一个包括所有的Banked ARM core register中选取。全部Banked ARM core register包括：

| Usr     | System | Hyp      | Supervisor | abort    | undefined | Monitor  | IRQ      | FIQ      |
| ------- | ------ | -------- | ---------- | -------- | --------- | -------- | -------- | -------- |
| R0_usr  |        |          |            |          |           |          |          |          |
| R1_usr  |        |          |            |          |           |          |          |          |
| R2_usr  |        |          |            |          |           |          |          |          |
| R3_usr  |        |          |            |          |           |          |          |          |
| R4_usr  |        |          |            |          |           |          |          |          |
| R5_usr  |        |          |            |          |           |          |          |          |
| R6_usr  |        |          |            |          |           |          |          |          |
| R7_usr  |        |          |            |          |           |          |          |          |
| R8_usr  |        |          |            |          |           |          |          | R8_fiq   |
| R9_usr  |        |          |            |          |           |          |          | R9_fiq   |
| R10_usr |        |          |            |          |           |          |          | R10_fiq  |
| R11_usr |        |          |            |          |           |          |          | R11_fiq  |
| R12_usr |        |          |            |          |           |          |          | R12_fiq  |
| SP_usr  |        | SP_hyp   | SP_svc     | SP_abt   | SP_und    | SP_mon   | SP_irq   | SP_fiq   |
| LR_usr  |        |          | LR_svc     | LR_abt   | LR_und    | LR_mon   | LR_irq   | LR_fiq   |
| PC      |        |          |            |          |           |          |          |          |
| CPSR    |        |          |            |          |           |          |          |          |
|         |        | SPSR_hyp | SPSR_svc   | SPSR_abt | SPSR_und  | SPSR_mon | SPSR_irq | SPSR_fiq |
|         |        | ELR_hyp  |            |          |           |          |          |          |

在IRQ mode下，CPU看到的R0~R12寄存器、PC以及CPSR是和usr mode(userspace)或者svc mode(kernel space)是一样的。不同的是IRQ mode下，有自己的R13(SP，stack pointer)、R14(LR，link register)和SPSR(Saved Program Status Register)。

CPSR是共用的，虽然中断可能发生在usr mode(用户空间)，也可能是svc mode(内核空间)，不过这些信息都是体现在CPSR寄存器中。硬件会将发生中断那一刻的CPSR保存在SPSR寄存器中(由于不同的mode下有不同的SPSR寄存器，因此更准确的说应该是SPSR-irq，也就是IRQ mode中的SPSR寄存器)。

PC也是共用的，由于后续PC会被修改为irq exception vector，因此有必要保存PC值。当然，与其说保存PC值，不如说是保存返回执行的地址。对于IRQ而言，我们期望返回地址是发生中断那一点执行指令的下一条指令。具体的返回地址保存在lr寄存器中(注意：这个lr寄存器是IRQ mode的lr寄存器，可以表示为lr_irq)：

(1) 对于thumb state，lr_irq = PC

(2) 对于ARM state，lr_irq = PC - 4

为何要减去4?我的理解是这样的(不一定对)。由于ARM采用流水线结构，当CPU正在执行某一条指令的时候，其实取指的动作早就执行了，这时候PC值=正在执行的指令地址 + 8，如下所示：

－－－－> 发生中断的指令

发生中断的指令+4

－PC－－>发生中断的指令+8

发生中断的指令+12

一旦发生了中断，当前正在执行的指令当然要执行完毕，但是已经完成取指、译码的指令则终止执行。当发生中断的指令执行完毕之后，原来指向(发生中断的指令+8)的PC会继续增加4，因此发生中断后，ARM core的硬件着手处理该中断的时候，硬件现场如下图所示：

－－－－> 发生中断的指令

发生中断的指令+4 <-------中断返回的指令是这条指令

发生中断的指令+8

－PC－－>发生中断的指令+12

这时候的PC值其实是比发生中断时候的指令超前12。减去4之后，lr_irq中保存了(发生中断的指令+8)的地址。为什么HW不帮忙直接减去8呢?这样，后续软件不就不用再减去4了。这里我们不能孤立的看待问题，实际上ARM的异常处理的硬件逻辑不仅仅处理IRQ的exception，还要处理各种exception，很遗憾，不同的exception期望的返回地址不统一，因此，硬件只是帮忙减去4，剩下的交给软件去调整。

3、 mask IRQ exception。也就是设定CPSR.I = 1

4、 设定PC值为IRQ exception vector。基本上，ARM处理器的硬件就只能帮你帮到这里了，一旦设定PC值，ARM处理器就会跳转到IRQ的exception vector地址了，后续的动作都是软件行为了。

### 四、如何进入ARM中断处理

#### 1、IRQ mode中的处理

IRQ mode的处理都在vector_irq中，vector_stub是一个宏，定义如下：

```assembly
.macro    vector_stub, name, mode, correction=0
.align    5
vector_\name:
.if \correction
sub    lr, lr, #\correction－－－－－－－－－－－－－(1)
.endif
@
@ Save r0, lr_ (parent PC) and spsr_
@ (parent CPSR)
@
stmia    sp, {r0, lr}        @ save r0, lr－－－－－－－－(2)
mrs    lr, spsr
str    lr, [sp, #8]        @ save spsr
@
@ Prepare for SVC32 mode.  IRQs remain disabled.
@
mrs    r0, cpsr－－－－－－－－－－－－－－－－－－－－－－－(3)
eor    r0, r0, #(\mode ^ SVC_MODE | PSR_ISETSTATE)
msr    spsr_cxsf, r0
@
@ the branch table must immediately follow this code
@
and    lr, lr, #0x0f－－－lr保存了发生IRQ时候的CPSR，通过and操作，可以获取CPSR.M[3:0]的值
这时候，如果中断发生在用户空间，lr=0，如果是内核空间，lr=3
THUMB( adr    r0, 1f            )－－－－根据当前PC值，获取lable 1的地址
THUMB( ldr    lr, [r0, lr, lsl #2]  )－lr根据当前mode，要么是__irq_usr的地址 ，要么是__irq_svc的地址
mov    r0, sp－－－－－－将irq mode的stack point通过r0传递给即将跳转的函数
ARM(    ldr    lr, [pc, lr, lsl #2]    )－－－根据mode，给lr赋值，__irq_usr或者__irq_svc
movs    pc, lr            @ branch to handler in SVC mode－－－－－(4)
ENDPROC(vector_\name)
.align    2
@ handler addresses follow this label
1:
.endm
```

(1) 我们期望在栈上保存发生中断时候的硬件现场(HW context)，这里就包括ARM的core register。上一章我们已经了解到，当发生IRQ中断的时候，lr中保存了发生中断的PC+4，如果减去4的话，得到的就是发生中断那一点的PC值。

(2) 当前是IRQ mode，SP_irq在初始化的时候已经设定(12个字节)。在irq mode的stack上，依次保存了发生中断那一点的r0值、PC值以及CPSR值(具体操作是通过spsr进行的，其实硬件已经帮我们保存了CPSR到SPSR中了)。为何要保存r0值?因为随后的代码要使用r0寄存器，因此我们要把r0放到栈上，只有这样才能完完全全恢复硬件现场。

(3) 可怜的IRQ mode稍纵即逝，这段代码就是准备将ARM推送到SVC mode。如何准备?其实就是修改SPSR的值，SPSR不是CPSR，不会引起processor mode的切换(毕竟这一步只是准备而已)。

(4) 很多异常处理的代码返回的时候都是使用了stack相关的操作，这里没有。“movs    pc, lr ”指令除了字面上意思(把lr的值付给pc)，还有一个隐含的操作(movs中‘s’的含义)：把SPSR copy到CPSR，从而实现了模式的切换。

#### 2、当发生中断的时候，代码运行在用户空间

Interrupt dispatcher的代码如下：

```assembly
vector_stub    irq, IRQ_MODE, 4 －－－－－减去4，确保返回发生中断之后的那条指令
.long    __irq_usr            @  0  (USR_26 / USR_32)   <---------------------> base address + 0
.long    __irq_invalid            @  1  (FIQ_26 / FIQ_32)
.long    __irq_invalid            @  2  (IRQ_26 / IRQ_32)
.long    __irq_svc            @  3  (SVC_26 / SVC_32)<---------------------> base address + 12
.long    __irq_invalid            @  4
.long    __irq_invalid            @  5
.long    __irq_invalid            @  6
.long    __irq_invalid            @  7
.long    __irq_invalid            @  8
.long    __irq_invalid            @  9
.long    __irq_invalid            @  a
.long    __irq_invalid            @  b
.long    __irq_invalid            @  c
.long    __irq_invalid            @  d
.long    __irq_invalid            @  e
.long    __irq_invalid            @  f
```

这其实就是一个lookup table，根据CPSR.M[3:0]的值进行跳转(参考上一节的代码：and    lr, lr, #0x0f)。因此，该lookup table共设定了16个入口，当然只有两项有效，分别对应user mode和svc mode的跳转地址。其他入口的__irq_invalid也是非常关键的，这保证了在其模式下发生了中断，系统可以捕获到这样的错误，为debug提供有用的信息。

```assembly
.align    5
__irq_usr:
usr_entry－－－－－－－－－请参考本章第一节(1)保存用户现场的描述
kuser_cmpxchg_check－－－和本文描述的内容无关，这些不就介绍了
irq_handler－－－－－－－－－－核心处理内容，请参考本章第二节的描述
get_thread_info tsk－－－－－－tsk是r9，指向当前的thread info数据结构
mov    why, #0－－－－－－－－why是r8
b    ret_to_user_from_irq－－－－中断返回，下一章会详细描述
why其实就是r8寄存器，用来传递参数的，表示本次放回用户空间相关的系统调用是哪个?中断处理这个场景和系统调用无关，因此设定为0。
(1)保存发生中断时候的现场。所谓保存现场其实就是把发生中断那一刻的硬件上下文(各个寄存器)保存在了SVC mode的stack上。
.macro    usr_entry
sub    sp, sp, #S_FRAME_SIZE－－－－－－－－－－－－－－A
stmib    sp, {r1 - r12} －－－－－－－－－－－－－－－－－－－B
ldmia    r0, {r3 - r5}－－－－－－－－－－－－－－－－－－－－C
add    r0, sp, #S_PC－－－－－－－－－－－－－－－－－－－D
mov    r6, #-1－－－－orig_r0的值
str    r3, [sp] －－－－保存中断那一刻的r0
stmia    r0, {r4 - r6}－－－－－－－－－－－－－－－－－－－－E
stmdb    r0, {sp, lr}^－－－－－－－－－－－－－－－－－－－F
.endm
```

A：代码执行到这里的时候，ARM处理已经切换到了SVC mode。一旦进入SVC mode，ARM处理器看到的寄存器已经发生变化，这里的sp已经变成了sp_svc了。因此，后续的压栈操作都是压入了发生中断那一刻的进程的(或者内核线程)内核栈(svc mode栈)。具体保存多少个寄存器值?S_FRAME_SIZE已经给出了答案，这个值是18个寄存器。r0~r15再加上CPSR也只有17个而已。先保留这个疑问，我们稍后回答。

B：压栈首先压入了r1~r12，这里为何不处理r0?因为r0在irq mode切到svc mode的时候被污染了，不过，原始的r0被保存的irq mode的stack上了。r13(sp)和r14(lr)需要保存吗，当然需要，稍后再保存。执行到这里，内核栈的布局如下图所示：

![](attachment\6.1.gif)

stmib中的ib表示increment before，因此，在压入R1的时候，stack pointer会先增加4，重要是预留r0的位置。stmib    sp, {r1 - r12}指令中的sp没有“!”的修饰符，表示压栈完成后并不会真正更新stack pointer，因此sp保持原来的值。

C：注意，这里r0指向了irq stack，因此，r3是中断时候的r0值，r4是中断现场的PC值，r5是中断现场的CPSR值。

D：把r0赋值为S_PC的值。根据struct pt_regs的定义(这个数据结构反应了内核栈上的保存的寄存器的排列信息)，从低地址到高地址依次为：

```c
ARM_r0
ARM_r1
ARM_r2
ARM_r3
ARM_r4
ARM_r5
ARM_r6
ARM_r7
ARM_r8
ARM_r9
ARM_r10
ARM_fp
ARM_ip
ARM_sp
ARM_lr
ARM_pc<---------add    r0, sp, #S_PC指令使得r0指向了这个位置
ARM_cpsr
ARM_ORIG_r0
```

为什么要给r0赋值?因此kernel不想修改sp的值，保持sp指向栈顶。

E：在内核栈上保存剩余的寄存器的值，根据代码，依次是r0，PC，CPSR和orig r0。执行到这里，内核栈的布局如下图所示：

![](attachment\6.2.gif)

R0，PC和CPSR来自IRQ mode的stack。实际上这段操作就是从irq stack就中断现场搬移到内核栈上。

F：内核栈上还有两个寄存器没有保持，分别是发生中断时候sp和lr这两个寄存器。这时候，r0指向了保存PC寄存器那个地址(add    r0, sp, #S_PC)，stmdb    r0, {sp, lr}^中的“db”是decrement before，因此，将sp和lr压入stack中的剩余的两个位置。需要注意的是，我们保存的是发生中断那一刻(对于本节，这是当时user mode的sp和lr)，指令中的“^”符号表示访问user mode的寄存器。

(2) 核心处理

irq_handler的处理有两种配置。一种是配置了CONFIG_MULTI_IRQ_HANDLER。这种情况下，linux kernel允许run time设定irq handler。如果我们需要一个linux kernel image支持多个平台，这是就需要配置这个选项。另外一种是传统的linux的做法，irq_handler实际上就是arch_irq_handler_default，具体代码如下：

```addembly
.macro    irq_handler
#ifdef CONFIG_MULTI_IRQ_HANDLER
ldr    r1, =handle_arch_irq
mov    r0, sp－－－－－－－－设定传递给machine定义的handle_arch_irq的参数
adr    lr, BSYM(9997f)－－－－设定返回地址
ldr    pc, [r1]
#else
arch_irq_handler_default
#endif
9997:
.endm
```

对于情况一，machine相关代码需要设定handle_arch_irq函数指针，这里的汇编指令只需要调用这个machine代码提供的irq handler即可(当然，要准备好参数传递和返回地址设定)。

情况二要稍微复杂一些(而且，看起来kernel中使用的越来越少)，代码如下：

```assembly
.macro    arch_irq_handler_default
get_irqnr_preamble r6, lr
1:    get_irqnr_and_base r0, r2, r6, lr
movne    r1, sp
@
@ asm_do_IRQ 需要两个参数，一个是 irq number(保存在r0)
@                                          另一个是 struct pt_regs *(保存在r1中)
adrne    lr, BSYM(1b)－－－－－－－返回地址设定为符号1，也就是说要不断的解析irq状态寄存器
的内容，得到IRQ number，直到所有的irq number处理完毕
bne    asm_do_IRQ
.endm
```

这里的代码已经是和machine相关的代码了，我们这里只是简短描述一下。所谓machine相关也就是说和系统中的中断控制器相关了。get_irqnr_preamble是为中断处理做准备，有些平台根本不需要这个步骤，直接定义为空即可。get_irqnr_and_base 有四个参数，分别是：r0保存了本次解析的irq number，r2是irq状态寄存器的值，r6是irq controller的base address，lr是scratch register。

对于ARM平台而言，我们推荐使用第一种方法，因为从逻辑上讲，中断处理就是需要根据当前的硬件中断系统的状态，转换成一个IRQ number，然后调用该IRQ number的处理函数即可。通过get_irqnr_and_base这样的宏定义来获取IRQ是旧的ARM SOC系统使用的方法，它是假设SOC上有一个中断控制器，硬件状态和IRQ number之间的关系非常简单。但是实际上，ARM平台上的硬件中断系统已经是越来越复杂了，需要引入interrupt controller级联，irq domain等等概念，因此，使用第一种方法优点更多。

3、当发生中断的时候，代码运行在内核空间

如果中断发生在内核空间，代码会跳转到__irq_svc处执行：

```c
.align    5
__irq_svc:
svc_entry－－－－保存发生中断那一刻的现场保存在内核栈上
irq_handler －－－－具体的中断处理，同user mode的处理。
#ifdef CONFIG_PREEMPT－－－－－－－－和preempt相关的处理
get_thread_info tsk
ldr    r8, [tsk, #TI_PREEMPT]        @ get preempt count
ldr    r0, [tsk, #TI_FLAGS]        @ get flags
teq    r8, #0                @ if preempt count != 0
movne    r0, #0                @ force flags to 0
tst    r0, #_TIF_NEED_RESCHED
blne    svc_preempt
#endif
svc_exit r5, irq = 1            @ return from exception
一个task的thread info数据结构定义如下(只保留和本场景相关的内容)：
struct thread_info {
    unsigned long        flags;        /* low level flags */
    int            preempt_count;    /* 0 => preemptable, <0 => bug */
    ……
};
```



flag成员用来标记一些low level的flag，而preempt_count用来判断当前是否可以发生抢占，如果preempt_count不等于0(可能是代码调用preempt_disable显式的禁止了抢占，也可能是处于中断上下文等)，说明当前不能进行抢占，直接进入恢复现场的工作。如果preempt_count等于0，说明已经具备了抢占的条件，当然具体是否要抢占当前进程还是要看看thread info中的flag成员是否设定了_TIF_NEED_RESCHED这个标记(可能是当前的进程的时间片用完了，也可能是由于中断唤醒了优先级更高的进程)。

保存现场的代码和user mode下的现场保存是类似的，因此这里不再详细描述，只是在下面的代码中内嵌一些注释。

```assembly
.macro    svc_entry, stack_hole=0
sub    sp, sp, #(S_FRAME_SIZE + \stack_hole - 4)－－－－sp指向struct pt_regs中r1的位置
stmia    sp, {r1 - r12} －－－－－－寄存器入栈。
ldmia    r0, {r3 - r5}
add    r7, sp, #S_SP - 4 －－－－－－r7指向struct pt_regs中r12的位置
mov    r6, #-1 －－－－－－－－－－orig r0设为-1
add    r2, sp, #(S_FRAME_SIZE + \stack_hole - 4)－－－－r2是发现中断那一刻stack的现场
str    r3, [sp, #-4]! －－－－保存r0，注意有一个!，sp会加上4，这时候sp就指向栈顶的r0位置了
mov    r3, lr －－－－保存svc mode的lr到r3
stmia    r7, {r2 - r6} －－－－－－－－－压栈，在栈上形成形成struct pt_regs
.endm
```

至此，在内核栈上保存了完整的硬件上下文。实际上不但完整，而且还有些冗余，因为其中有一个orig_r0的成员。所谓original r0就是发生中断那一刻的r0值，按理说，ARM_r0和ARM_ORIG_r0都应该是用户空间的那个r0。 为何要保存两个r0值呢?为何中断将-1保存到了ARM_ORIG_r0位置呢?理解这个问题需要跳脱中断处理这个主题，我们来看ARM的系统调用。对于系统调用，它 和中断处理虽然都是cpu异常处理范畴，但是一个明显的不同是系统调用需要传递参数，返回结果。如果进行这样的参数传递呢?对于ARM，当然是寄存器了， 特别是返回结果，保存在了r0中。对于ARM，r0~r7是各种cpu mode都相同的，用于传递参数还是很方便的。因此，进入系统调用的时候，在内核栈上保存了发生系统调用现场的所有寄存器，一方面保存了hardware context，另外一方面，也就是获取了系统调用的参数。返回的时候，将返回值放到r0就OK了。

根据上面的描述，r0有两个作用，传递参数，返回结果。当把系统调用的结果放到r0的时候，通过r0传递的参数值就被覆盖了。本来，这也没有什么，但是有些场合是需要需要这两个值的：

1、ptrace (和debugger相关，这里就不再详细描述了)

2、system call restart (和signal相关，这里就不再详细描述了)

正因为如此，硬件上下文的寄存器中r0有两份，ARM_r0是传递的参数，并复制一份到ARM_ORIG_r0，当系统调用返回的时候，ARM_r0是系统调用的返回值。

OK，我们再回到中断这个主题，其实在中断处理过程中，没有使用ARM_ORIG_r0这个值，但是，为了防止system call restart，可以赋值为非系统调用号的值(例如-1)。

### 五、中断退出过程

无论是在内核态(包括系统调用和中断上下文)还是用户态，发生了中断后都会调用irq_handler进行处理，这里会调用对应的irq number的handler，处理softirq、tasklet、workqueue等(这些内容另开一个文档描述)，但无论如何，最终都是要返回发生中断的现场。

1、中断发生在user mode下的退出过程，代码如下：

```assembly
ENTRY(ret_to_user_from_irq)
ldr    r1, [tsk, #TI_FLAGS]
tst    r1, #_TIF_WORK_MASK－－－－－－－－－－－－－－－A
bne    work_pending
no_work_pending:
asm_trace_hardirqs_on －－－－－－和irq flag trace相关，暂且略过
/* perform architecture specific actions before user return */
arch_ret_to_user r1, lr－－－－有些硬件平台需要在中断返回用户空间做一些特别处理
ct_user_enter save = 0 －－－－和trace context相关，暂且略过
restore_user_regs fast = 0, offset = 0－－－－－－－－－－－－B
ENDPROC(ret_to_user_from_irq)
ENDPROC(ret_to_user)
```

A：thread_info中的flags成员中有一些low level的标识，如果这些标识设定了就需要进行一些特别的处理，这里检测的flag主要包括：

```c
#define _TIF_WORK_MASK   (_TIF_NEED_RESCHED | _TIF_SIGPENDING | _TIF_NOTIFY_RESUME)
```

这三个flag分别表示是否需要调度、是否有信号处理、返回用户空间之前是否需要调用callback函数。只要有一个flag被设定了，程序就进入work_pending这个分支(work_pending函数需要传递三个参数，第三个是参数why是标识哪一个系统调用，当然，我们这里传递的是0)。

B：从字面的意思也可以看成，这部分的代码就是将进入中断的时候保存的现场(寄存器值)恢复到实际的ARM的各个寄存器中，从而完全返回到了中断发生的那一点。具体的代码如下：

```assembly
.macro    restore_user_regs, fast = 0, offset = 0
ldr    r1, [sp, #\offset + S_PSR] －－－－r1保存了pt_regs中的spsr，也就是发生中断时的CPSR
ldr    lr, [sp, #\offset + S_PC]!    －－－－lr保存了PC值，同时sp移动到了pt_regs中PC的位置
msr    spsr_cxsf, r1 －－－－－－－－－赋值给spsr，进行返回用户空间的准备
clrex                    @ clear the exclusive monitor
.if    \fast
ldmdb    sp, {r1 - lr}^            @ get calling r1 - lr
.else
ldmdb    sp, {r0 - lr}^ －－－－－－将保存在内核栈上的数据保存到用户态的r0~r14寄存器
.endif
mov    r0, r0   －－－－－－－－－NOP操作，ARMv5T之前的需要这个操作
add    sp, sp, #S_FRAME_SIZE - S_PC－－－－现场已经恢复，移动svc mode的sp到原来的位置
movs    pc, lr               －－－－－－－－返回用户空间
.endm
```

2、中断发生在svc mode下的退出过程。具体代码如下：

```assembly
.macro    svc_exit, rpsr, irq = 0
.if    \irq != 0
@ IRQs already off
.else
@ IRQs off again before pulling preserved data off the stack
disable_irq_notrace
.endif
msr    spsr_cxsf, \rpsr－－－－－－－将中断现场的cpsr值保存到spsr中，准备返回中断发生的现场
ldmia    sp, {r0 - pc}^ －－－－－这条指令是ldm异常返回指令，这条指令除了字面上的操作，
还包括了将spsr copy到cpsr中。
.endm
```



## (七)：GIC代码分析

一、前言

GIC(Generic Interrupt Controller)是ARM公司提供的一个通用的中断控制器，其architecture specification目前有四个版本，V1~V4(V2最多支持8个ARM core，V3/V4支持更多的ARM core，主要用于ARM64服务器系统结构)。目前在ARM官方网站只能下载到Version 2的GIC architecture specification，因此，本文主要描述符合V2规范的GIC硬件及其驱动。

具体GIC硬件的实现形态有两种，一种是在ARM vensor研发自己的SOC的时候，会向ARM公司购买GIC的IP，这些IP包括的型号有：PL390，GIC-400，GIC-500。其中GIC-500最多支持128个 cpu core，它要求ARM core必须是ARMV8指令集的(例如Cortex-A57)，符合GIC architecture specification version 3。另外一种形态是ARM vensor直接购买ARM公司的Cortex A9或者A15的IP，Cortex A9或者A15中会包括了GIC的实现，当然，这些实现也是符合GIC V2的规格。

本文在进行硬件描述的时候主要是以GIC-400为目标，当然，也会顺便提及一些Cortex A9或者A15上的GIC实现。

本文主要分析了linux kernel中GIC中断控制器的驱动代码(位于drivers/irqchip/irq-gic.c和irq-gic-common.c)。 irq-gic-common.c中是GIC V2和V3的通用代码，而irq-gic.c是V2 specific的代码，irq-gic-v3.c是V3 specific的代码，不在本文的描述范围。本文主要分成三个部分：第二章描述了GIC V2的硬件；第三章描述了GIC V2的初始化过程；第四章描述了底层的硬件call back函数。

注：具体的linux kernel的版本是linux-3.17-rc3。

二、GIC-V2的硬件描述

1、GIC-V2的输入和输出信号

(1)GIC-V2的输入和输出信号示意图

要想理解一个building block(无论软件还是硬件)，我们都可以先把它当成黑盒子，只是研究其input，output。GIC-V2的输入和输出信号的示意图如下(注：我们以GIC-400为例，同时省略了clock，config等信号)：

![](attachment\7.1.gif)

(2)输入信号

上图中左边就是来自外设的interrupt source输入信号。分成两种类型，分别是PPI(Private Peripheral Interrupt)和SPI(Shared Peripheral Interrupt)。其实从名字就可以看出来两种类型中断信号的特点，PPI中断信号是CPU私有的，每个CPU都有其特定的PPI信号线。而SPI是所有CPU之间共享的。通过寄存器GICD_TYPER可以配置SPI的个数(最多480个)。GIC-400支持多少个SPI中断，其输入信号线就有多少个SPI interrupt request signal。同样的，通过寄存器GICD_TYPER也可以配置CPU interface的个数(最多8个)，GIC-400支持多少个CPU interface，其输入信号线就提供多少组PPI中断信号线。一组PPI中断信号线包括6个实际的signal：

(a)nLEGACYIRQ信号线。对应interrupt ID 31，在bypass mode下(这里的bypass是指bypass GIC functionality，直接连接到某个processor上)，nLEGACYIRQ可以直接连到对应CPU的nIRQCPU信号线上。在这样的设置下，该CPU不参与其他属于该CPU的PPI以及SPI中断的响应，而是特别为这一根中断线服务。

(b)nCNTPNSIRQ信号线。来自Non-secure physical timer的中断事件，对应interrupt ID 30。

(c)nCNTPSIRQ信号线。来自secure physical timer的中断事件，对应interrupt ID 29。

(d)nLEGACYFIQ信号线。对应interrupt ID 28。概念同nLEGACYIRQ信号线，不再描述。

(e)nCNTVIRQ信号线。对应interrupt ID 27。Virtual Timer Event，和虚拟化相关，这里不与描述。

(f)nCNTHPIRQ信号线。对应interrupt ID 26。Hypervisor Timer Event，和虚拟化相关，这里不与描述。

对于Cortex A15的GIC实现，其PPI中断信号线除了上面的6个，还有一个叫做Virtual Maintenance Interrupt，对应interrupt ID 25。

对于Cortex A9的GIC实现，其PPI中断信号线包括5根：

(a)nLEGACYIRQ信号线和nLEGACYFIQ信号线。对应interrupt ID 31和interrupt ID 28。这部分和上面一致。

(b)由于Cortext A9的每个处理器都有自己的Private timer和watch dog timer，这两个HW block分别使用了ID 29和ID 30

(c)Cortext A9内嵌一个global timer为系统内的所有processor共享，对应interrupt ID 27

关于private timer和global timer的描述，请参考时间子系统的相关文档。

关于一系列和虚拟化相关的中断，请参考虚拟化的系列文档。

(3)输出信号

所谓输出信号，其实就是GIC和各个CPU直接的接口，这些接口包括：

(a)触发CPU中断的信号。nIRQCPU和nFIQCPU信号线，熟悉ARM CPU的工程师对这两个信号线应该不陌生，主要用来触发ARM cpu进入IRQ mode和FIQ mode。

(b)Wake up信号。nFIQOUT和nIRQOUT信号线，去ARM CPU的电源管理模块，用来唤醒CPU的

(c)AXI slave interface signals。AXI(Advanced eXtensible Interface)是一种总线协议，属于AMBA规范的一部分。通过这些信号线，ARM CPU可以和GIC硬件block进行通信(例如寄存器访问)。

(4)中断号的分配

GIC-V2支持的中断类型有下面几种：

(a)外设中断(Peripheral interrupt)。有实际物理interrupt request signal的那些中断，上面已经介绍过了。

(b)软件触发的中断(SGI，Software-generated interrupt)。软件可以通过写GICD_SGIR寄存器来触发一个中断事件，这样的中断，可以用于processor之间的通信。

(c)虚拟中断(Virtual interrupt)和Maintenance interrupt。这两种中断和本文无关，不再赘述。

为了标识这些interrupt source，我们必须要对它们进行编码，具体的ID分配情况如下：

(a)ID0~ID31是用于分发到一个特定的process的interrupt。标识这些interrupt不能仅仅依靠ID，因为各个interrupt source都用同样的ID0~ID31来标识，因此识别这些interrupt需要interrupt ID + CPU interface number。ID0~ID15用于SGI，ID16~ID31用于PPI。PPI类型的中断会送到其私有的process上，和其他的process无关。SGI是通过写GICD_SGIR寄存器而触发的中断。Distributor通过processor source ID、中断ID和target processor ID来唯一识别一个SGI。

(b)ID32~ID1019用于SPI。 这是GIC规范的最大size，实际上GIC-400最大支持480个SPI，Cortex-A15和A9上的GIC最多支持224个SPI。

2、GIC-V2的内部逻辑

(1)GIC的block diagram

GIC的block diagram如下图所示：

![](attachment\7.2.gif)

GIC可以清晰的划分成两个block，一个block是Distributor(上图的左边的block)，一个是CPU interface。CPU interface有两种，一种就是和普通processor接口，另外一种是和虚拟机接口的。Virtual CPU interface在本文中不会详细描述。

(2)Distributor 概述

Distributor的主要的作用是检测各个interrupt source的状态，控制各个interrupt source的行为，分发各个interrupt source产生的中断事件分发到指定的一个或者多个CPU interface上。虽然Distributor可以管理多个interrupt source，但是它总是把优先级最高的那个interrupt请求送往CPU interface。Distributor对中断的控制包括：

(1)中断enable或者disable的控制。Distributor对中断的控制分成两个级别。一个是全局中断的控制(GIC_DIST_CTRL)。一旦disable了全局的中断，那么任何的interrupt source产生的interrupt event都不会被传递到CPU interface。另外一个级别是对针对各个interrupt source进行控制(GIC_DIST_ENABLE_CLEAR)，disable某一个interrupt source会导致该interrupt event不会分发到CPU interface，但不影响其他interrupt source产生interrupt event的分发。

(2)控制将当前优先级最高的中断事件分发到一个或者一组CPU interface。当一个中断事件分发到多个CPU interface的时候，GIC的内部逻辑应该保证只assert 一个CPU。

(3)优先级控制。

(4)interrupt属性设定。例如是level-sensitive还是edge-triggered

(5)interrupt group的设定

Distributor可以管理若干个interrupt source，这些interrupt source用ID来标识，我们称之interrupt ID。

(3)CPU interface

CPU interface这个block主要用于和process进行接口。该block的主要功能包括：

(a)enable或者disable CPU interface向连接的CPU assert中断事件。对于ARM，CPU interface block和CPU之间的中断信号线是nIRQCPU和nFIQCPU。如果disable了中断，那么即便是Distributor分发了一个中断事件到CPU interface，但是也不会assert指定的nIRQ或者nFIQ通知processor。

(b)ackowledging中断。processor会向CPU interface block应答中断(应答当前优先级最高的那个中断)，中断一旦被应答，Distributor就会把该中断的状态从pending状态修改成active或者pending and active(这是和该interrupt source的信号有关，例如如果是电平中断并且保持了该asserted电平，那么就是pending and active)。processor ack了中断之后，CPU interface就会deassert nIRQCPU和nFIQCPU信号线。

(c)中断处理完毕的通知。当interrupt handler处理完了一个中断的时候，会向写CPU interface的寄存器从而通知GIC CPU已经处理完该中断。做这个动作一方面是通知Distributor将中断状态修改为deactive，另外一方面，CPU interface会priority drop，从而允许其他的pending的interrupt向CPU提交。

(d)设定priority mask。通过priority mask，可以mask掉一些优先级比较低的中断，这些中断不会通知到CPU。

(e)设定preemption的策略

(f)在多个中断事件同时到来的时候，选择一个优先级最高的通知processor

(4)实例

我们用一个实际的例子来描述GIC和CPU接口上的交互过程，具体过程如下：

![](attachment\7.3.gif)

(注：图片太长，因此竖着放，看的时候有点费劲，就当活动一下脖子吧)

首先给出前提条件：

(a)N和M用来标识两个外设中断，N的优先级大于M

(b)两个中断都是SPI类型，level trigger，active-high

(c)两个中断被配置为去同一个CPU

(d)都被配置成group 0，通过FIQ触发中断

下面的表格按照时间轴来描述交互过程：



| 时间     | 交互动作的描述                                  |
| ------ | ---------------------------------------- |
| T0时刻   | Distributor检测到M这个interrupt source的有效触发电平 |
| T2时刻   | Distributor将M这个interrupt source的状态设定为pending |
| T17时刻  | 大约15个clock之后，CPU interface拉低nFIQCPU信号线，向CPU报告M外设的中断请求。这时候，CPU interface的ack寄存器(GICC_IAR)的内容会修改成M interrupt source对应的ID |
| T42时刻  | Distributor检测到N这个优先级更高的interrupt source的触发事件 |
| T43时刻  | Distributor将N这个interrupt source的状态设定为pending。同时，由于N的优先级更高，因此Distributor会标记当前优先级最高的中断 |
| T58时刻  | 大约15个clock之后，CPU interface拉低nFIQCPU信号线，向CPU报告N外设的中断请求。当然，由于T17时刻已经assert CPU了，因此实际的电平信号仍然保持asserted。这时候，CPU interface的ack寄存器(GICC_IAR)的内容会被更新成N interrupt source的ID |
| T61时刻  | 软件通过读取ack寄存器的内容，获取了当前优先级最高的，并且状态是pending的interrupt ID(也就是N interrupt source对应的ID)，通过读该寄存器，CPU也就ack了该interrupt source N。这时候，Distributor将N这个interrupt source的状态设定为pending and active(因为是电平触发，只要外部仍然有asserted的电平信号，那么一定就是pending的，而该中断是正在被CPU处理的中断，因此状态是pending and active)<br>注意：T61标识CPU开始服务该中断 |
| T64时刻  | 3个clock之后，由于CPU已经ack了中断，因此GIC中CPU interface模块 deassert nFIQCPU信号线，解除发向该CPU的中断请求 |
| T126时刻 | 由于中断服务程序操作了N外设的控制寄存器(ack外设的中断)，因此N外设deassert了其interrupt request signal |
| T128时刻 | Distributor解除N外设的pending状态，因此N这个interrupt source的状态设定为active |
| T131时刻 | 软件操作End of Interrupt寄存器(向GICC_EOIR寄存器写入N对应的interrupt ID)，标识中断处理结束。Distributor将N这个interrupt source的状态修改为idle<br>注意：T61~T131是CPU服务N外设中断的的时间区域，这个期间，如果有高优先级的中断pending，会发生中断的抢占(硬件意义的)，这时候CPU interface会向CPU assert 新的中断。 |
| T146时刻 | 大约15个clock之后，Distributor向CPU interface报告当前pending且优先级最高的interrupt source，也就是M了。漫长的pending之后，M终于迎来了春天。CPU interface拉低nFIQCPU信号线，向CPU报告M外设的中断请求。这时候，CPU interface的ack寄存器(GICC_IAR)的内容会修改成M interrupt source对应的ID |
| T211时刻 | CPU ack M中断(通过读GICC_IAR寄存器)，开始处理低优先级的中断。 |




三、GIC-V2 irq chip driver的初始化过程

在linux-3.17-rc3\drivers\irqchip目录下保存在各种不同的中断控制器的驱动代码，这个版本的内核支持了GICV3。irq-gic-common.c是通用的GIC的驱动代码，可以被各个版本的GIC使用。irq-gic.c是用于V2版本的GIC controller，而irq-gic-v3.c是用于V3版本的GIC controller。

1、GIC的device node和GIC irq chip driver的匹配过程

(1)irq chip driver中的声明

在linux-3.17-rc3\drivers\irqchip目录下的irqchip.h文件中定义了IRQCHIP_DECLARE宏如下：

#define IRQCHIP_DECLARE(name, compat, fn) OF_DECLARE_2(irqchip, name, compat, fn)

#define OF_DECLARE_2(table, name, compat, fn) \

_OF_DECLARE(table, name, compat, fn, of_init_fn_2)

#define _OF_DECLARE(table, name, compat, fn, fn_type)            \

static const struct of_device_id __of_table_##name        \

__used __section(__##table##_of_table)            \

= { .compatible = compat,                \

.data = (fn == (fn_type)NULL) ? fn : fn  }

这个宏其实就是初始化了一个struct of_device_id的静态常量，并放置在__irqchip_of_table section中。irq-gic.c文件中使用IRQCHIP_DECLARE来定义了若干个静态的struct of_device_id常量，如下：

IRQCHIP_DECLARE(gic_400, "arm,gic-400", gic_of_init);

IRQCHIP_DECLARE(cortex_a15_gic, "arm,cortex-a15-gic", gic_of_init);

IRQCHIP_DECLARE(cortex_a9_gic, "arm,cortex-a9-gic", gic_of_init);

IRQCHIP_DECLARE(cortex_a7_gic, "arm,cortex-a7-gic", gic_of_init);

IRQCHIP_DECLARE(msm_8660_qgic, "qcom,msm-8660-qgic", gic_of_init);

IRQCHIP_DECLARE(msm_qgic2, "qcom,msm-qgic2", gic_of_init);

兼容GIC-V2的GIC实现有很多，不过其初始化函数都是一个。在linux kernel编译的时候，你可以配置多个irq chip进入内核，编译系统会把所有的IRQCHIP_DECLARE宏定义的数据放入到一个特殊的section中(section name是__irqchip_of_table)，我们称这个特殊的section叫做irq chip table。这个table也就保存了kernel支持的所有的中断控制器的ID信息(最重要的是驱动代码初始化函数和DT compatible string)。我们来看看struct of_device_id的定义：

struct of_device_id

{

char    name[32];－－－－－－要匹配的device node的名字

char    type[32];－－－－－－－要匹配的device node的类型

char    compatible[128];－－－匹配字符串(DT compatible string)，用来匹配适合的device node

const void *data;－－－－－－－－对于GIC，这里是初始化函数指针

};

这个数据结构主要被用来进行Device node和driver模块进行匹配用的。从该数据结构的定义可以看出，在匹配过程中，device name、device type和DT compatible string都是考虑的因素。更细节的内容请参考__of_device_is_compatible函数。

(2)device node

不同的GIC-V2的实现总会有一些不同，这些信息可以通过Device tree的机制来传递。Device node中定义了各种属性，其中就包括了memory资源，IRQ描述等信息，这些信息需要在初始化的时候传递给具体的驱动，因此需要一个Device node和driver模块的匹配过程。在Device Tree模块中会包括系统中所有的device node，如果我们的系统使用了GIC-400，那么系统的device node数据库中会有一个node是GIC-400的，一个示例性的GIC-400的device node(我们以瑞芯微的RK3288处理器为例)定义如下：

gic: interrupt-controller@ffc01000 {

compatible = "arm,gic-400";

interrupt-controller;

#interrupt-cells = <3>;

#address-cells = <0>;

reg = <0xffc01000 0x1000="">,－－－－Distributor address range

<0xffc02000 0x1000="">,－－－－－CPU interface address range

<0xffc04000 0x2000="">,－－－－－Virtual interface control block

<0xffc06000 0x2000="">;－－－－－Virtual CPU interfaces

interrupts = ;

};

(3)device node和irq chip driver的匹配

在machine driver初始化的时候会调用irqchip_init函数进行irq chip driver的初始化。在driver/irqchip/irqchip.c文件中定义了irqchip_init函数，如下：

void __init irqchip_init(void)

{

of_irq_init(__irqchip_begin);

}

__irqchip_begin就是内核irq chip table的首地址，这个table也就保存了kernel支持的所有的中断控制器的ID信息(用于和device node的匹配)。of_irq_init函数执行之前，系统已经完成了device tree的初始化，因此系统中的所有的设备节点都已经形成了一个树状结构，每个节点代表一个设备的device node。of_irq_init是在所有的device node中寻找中断控制器节点，形成树状结构(系统可以有多个interrupt controller，之所以形成中断控制器的树状结构，是为了让系统中所有的中断控制器驱动按照一定的顺序进行初始化)。之后，从root interrupt controller节点开始，对于每一个interrupt controller的device node，扫描irq chip table，进行匹配，一旦匹配到，就调用该interrupt controller的初始化函数，并把该中断控制器的device node以及parent中断控制器的device node作为参数传递给irq chip driver。。具体的匹配过程的代码属于Device Tree模块的内容，更详细的信息可以参考Device Tree代码分析文档。

2、GIC driver初始化代码分析

(1)gic_of_init的代码如下：

int __init gic_of_init(struct device_node *node, struct device_node *parent)

{

void __iomem *cpu_base;

void __iomem *dist_base;

u32 percpu_offset;

int irq;

dist_base = of_iomap(node, 0);----------------映射GIC Distributor的寄存器地址空间

cpu_base = of_iomap(node, 1);----------------映射GIC CPU interface的寄存器地址空间

if (of_property_read_u32(node, "cpu-offset", &percpu_offset))--------处理cpu-offset属性。

percpu_offset = 0;

gic_init_bases(gic_cnt, -1, dist_base, cpu_base, percpu_offset, node);))-----主处理过程，后面详述

if (!gic_cnt)

gic_init_physaddr(node); -----对于不支持big.LITTLE switcher(CONFIG_BL_SWITCHER)的系统，该函数为空。

if (parent) {--------处理interrupt级联

irq = irq_of_parse_and_map(node, 0); －－－解析second GIC的interrupts属性，并进行mapping，返回IRQ number

gic_cascade_irq(gic_cnt, irq);

}

gic_cnt++;

return 0;

}

我们首先看看这个函数的参数，node参数代表需要初始化的那个interrupt controller的device node，parent参数指向其parent。在映射GIC-400的memory map I/O space的时候，我们只是映射了Distributor和CPU interface的寄存器地址空间，和虚拟化处理相关的寄存器没有映射，因此这个版本的GIC driver应该是不支持虚拟化的(不知道后续版本是否支持，在一个嵌入式平台上支持虚拟化有实际意义吗?最先支持虚拟化的应该是ARM64+GICV3/4这样的平台)。

要了解cpu-offset属性，首先要了解什么是banked register。所谓banked register就是在一个地址上提供多个寄存器副本。比如说系统中有四个CPU，这些CPU访问某个寄存器的时候地址是一样的，但是对于banked register，实际上，不同的CPU访问的是不同的寄存器，虽然它们的地址是一样的。如果GIC没有banked register，那么需要提供根据CPU index给出一系列地址偏移，而地址偏移=cpu-offset * cpu-nr。

interrupt controller可以级联。对于root GIC，其传入的parent是NULL，因此不会执行级联部分的代码。对于second GIC，它是作为其parent(root GIC)的一个普通的irq source，因此，也需要注册该IRQ的handler。由此可见，非root的GIC的初始化分成了两个部分：一部分是作为一个interrupt controller，执行和root GIC一样的初始化代码。另外一方面，GIC又作为一个普通的interrupt generating device，需要象一个普通的设备驱动一样，注册其中断handler。理解irq_of_parse_and_map需要irq domain的知识，请参考linux kernel的中断子系统之(二)：irq domain介绍。

(2)gic_init_bases的代码如下：

void __init gic_init_bases(unsigned int gic_nr, int irq_start,

void __iomem *dist_base, void __iomem *cpu_base,

u32 percpu_offset, struct device_node *node)

{

irq_hw_number_t hwirq_base;

struct gic_chip_data *gic;

int gic_irqs, irq_base, i;

gic = &gic_data[gic_nr];

gic->dist_base.common_base = dist_base; －－－－省略了non banked的情况

gic->cpu_base.common_base = cpu_base;

gic_set_base_accessor(gic, gic_get_common_base);

for (i = 0; i < NR_GIC_CPU_IF; i++) －－－后面会具体描述gic_cpu_map的含义

gic_cpu_map[i] = 0xff;

if (gic_nr == 0 && (irq_start & 31) > 0) { －－－－－－－－－－－－－－－－－－－－(a)

hwirq_base = 16;

if (irq_start != -1)

irq_start = (irq_start & ~31) + 16;

} else {

hwirq_base = 32;

}

gic_irqs = readl_relaxed(gic_data_dist_base(gic) + GIC_DIST_CTR) & 0x1f; －－－－(b)

gic_irqs = (gic_irqs + 1) * 32;

if (gic_irqs > 1020)

gic_irqs = 1020;

gic->gic_irqs = gic_irqs;

gic_irqs -= hwirq_base;－－－－－－－－－－－－－－－－－－－－－－－－－－－－(c)

if (of_property_read_u32(node, "arm,routable-irqs",－－－－－－－－－－－－－－－－(d)

&nr_routable_irqs)) {

irq_base = irq_alloc_descs(irq_start, 16, gic_irqs,  numa_node_id()); －－－－－－－(e)

if (IS_ERR_VALUE(irq_base)) {

WARN(1, "Cannot allocate irq_descs @ IRQ%d, assuming pre-allocated\n",

irq_start);

irq_base = irq_start;

}

gic->domain = irq_domain_add_legacy(node, gic_irqs, irq_base, －－－－－－－(f)

hwirq_base, &gic_irq_domain_ops, gic);

} else {

gic->domain = irq_domain_add_linear(node, nr_routable_irqs, －－－－－－－－(f)

&gic_irq_domain_ops,

gic);

}

if (gic_nr == 0) { －－－只对root GIC操作，因为设定callback、注册Notifier只需要一次就OK了

#ifdef CONFIG_SMP

set_smp_cross_call(gic_raise_softirq);－－－－－－－－－－－－－－－－－－(g)

register_cpu_notifier(&gic_cpu_notifier);－－－－－－－－－－－－－－－－－－(h)

#endif

set_handle_irq(gic_handle_irq); －－－这个函数名字也不好，实际上是设定arch相关的irq handler

}

gic_chip.flags |= gic_arch_extn.flags;

gic_dist_init(gic);---------具体的硬件初始代码，参考下节的描述

gic_cpu_init(gic);

gic_pm_init(gic);

}

(a)gic_nr标识GIC number，等于0就是root GIC。hwirq的意思就是GIC上的HW interrupt ID，并不是GIC上的每个interrupt ID都有map到linux IRQ framework中的一个IRQ number，对于SGI，是属于软件中断，用于CPU之间通信，没有必要进行HW interrupt ID到IRQ number的mapping。变量hwirq_base表示该GIC上要进行map的base ID，hwirq_base = 16也就意味着忽略掉16个SGI。对于系统中其他的GIC，其PPI也没有必要mapping，因此hwirq_base = 32。

在本场景中，irq_start = -1，表示不指定IRQ number。有些场景会指定IRQ number，这时候，需要对IRQ number进行一个对齐的操作。

(b)变量gic_irqs保存了该GIC支持的最大的中断数目。该信息是从GIC_DIST_CTR寄存器(这是V1版本的寄存器名字，V2中是GICD_TYPER，Interrupt Controller Type Register,)的低五位ITLinesNumber获取的。如果ITLinesNumber等于N，那么最大支持的中断数目是32(N+1)。此外，GIC规范规定最大的中断数目不能超过1020，1020-1023是有特别用户的interrupt ID。

(c)减去不需要map(不需要分配IRQ)的那些interrupt ID，OK，这时候gic_irqs的数值终于和它的名字一致了。gic_irqs从字面上看不就是该GIC需要分配的IRQ number的数目吗?

(d)of_property_read_u32函数把arm,routable-irqs的属性值读出到nr_routable_irqs变量中，如果正确返回0。在有些SOC的设计中，外设的中断请求信号线不是直接接到GIC，而是通过crossbar/multiplexer这个的HW block连接到GIC上。arm,routable-irqs这个属性用来定义那些不直接连接到GIC的中断请求数目。

(e)对于那些直接连接到GIC的情况，我们需要通过调用irq_alloc_descs分配中断描述符。如果irq_start大于0，那么说明是指定IRQ number的分配，对于我们这个场景，irq_start等于-1，因此不指定IRQ 号。如果不指定IRQ number的，就需要搜索，第二个参数16就是起始搜索的IRQ number。gic_irqs指明要分配的irq number的数目。如果没有正确的分配到中断描述符，程序会认为可能是之前已经准备好了。

(f)这段代码主要是向系统中注册一个irq domain的数据结构。为何需要struct irq_domain这样一个数据结构呢?从linux kernel的角度来看，任何外部的设备的中断都是一个异步事件，kernel都需要识别这个事件。在内核中，用IRQ number来标识某一个设备的某个interrupt request。有了IRQ number就可以定位到该中断的描述符(struct irq_desc)。但是，对于中断控制器而言，它不并知道IRQ number，它只是知道HW interrupt number(中断控制器会为其支持的interrupt source进行编码，这个编码被称为Hardware interrupt number )。不同的软件模块用不同的ID来识别interrupt source，这样就需要映射了。如何将Hardware interrupt number 映射到IRQ number呢?这需要一个translation object，内核定义为struct irq_domain。

每个interrupt controller都会形成一个irq domain，负责解析其下游的interrut source。如果interrupt controller有级联的情况，那么一个非root interrupt controller的中断控制器也是其parent irq domain的一个普通的interrupt source。struct irq_domain定义如下：

struct irq_domain {

……

const struct irq_domain_ops *ops;

void *host_data;

……

};

这个数据结构是属于linux kernel通用中断子系统的一部分，我们这里只是描述相关的数据成员。host_data成员是底层interrupt controller的私有数据，linux kernel通用中断子系统不应该修改它。对于GIC而言，host_data成员指向一个struct gic_chip_data的数据结构，定义如下：

struct gic_chip_data {

union gic_base dist_base;－－－－－－－－－－－－－－－－－－GIC Distributor的基地址空间

union gic_base cpu_base;－－－－－－－－－－－－－－－－－－GIC CPU interface的基地址空间

#ifdef CONFIG_CPU_PM－－－－－－－－－－－－－－－－－－－－GIC 电源管理相关的成员

u32 saved_spi_enable[DIV_ROUND_UP(1020, 32)];

u32 saved_spi_conf[DIV_ROUND_UP(1020, 16)];

u32 saved_spi_target[DIV_ROUND_UP(1020, 4)];

u32 __percpu *saved_ppi_enable;

u32 __percpu *saved_ppi_conf;

#endif

struct irq_domain *domain;－－－－－－－－－－－－－－－－－该GIC对应的irq domain数据结构

unsigned int gic_irqs;－－－－－－－－－－－－－－－－－－－GIC支持的IRQ的数目

#ifdef CONFIG_GIC_NON_BANKED

void __iomem *(*get_base)(union gic_base *);

#endif

};

对于GIC支持的IRQ的数目，这里还要赘述几句。实际上并非GIC支持多少个HW interrupt ID，其就支持多少个IRQ。对于SGI，其处理比较特别，并不归入IRQ number中。因此，对于GIC而言，其SGI(从0到15的那些HW interrupt ID)不需要irq domain进行映射处理，也就是说SGI没有对应的IRQ number。如果系统越来越复杂，一个GIC不能支持所有的interrupt source(目前GIC支持1020个中断源，这个数目已经非常的大了)，那么系统还需要引入secondary GIC，这个GIC主要负责扩展外设相关的interrupt source，也就是说，secondary GIC的SGI和PPI都变得冗余了(这些功能，primary GIC已经提供了)。这些信息可以协助理解代码中的hwirq_base的设定。

在注册GIC的irq domain的时候还有一个重要的数据结构gic_irq_domain_ops，其类型是struct irq_domain_ops ，对于GIC，其irq domain的操作函数是gic_irq_domain_ops，定义如下：

static const struct irq_domain_ops gic_irq_domain_ops = {

.map = gic_irq_domain_map,

.unmap = gic_irq_domain_unmap,

.xlate = gic_irq_domain_xlate,

};

irq domain的概念是一个通用中断子系统的概念，在具体的irq chip driver这个层次，我们需要一些解析GIC binding，创建IRQ number和HW interrupt ID的mapping的callback函数，更具体的解析参考后文的描述。

漫长的准备过程结束后，具体的注册比较简单，调用irq_domain_add_legacy或者irq_domain_add_linear进行注册就OK了。关于这两个接口请参考linux kernel的中断子系统之(二)：irq domain介绍。

(g) 一个函数名字是否起的好足可以看出工程师的功力。set_smp_cross_call这个函数看名字也知道它的含义，就是设定一个多个CPU直接通信的callback函数。当一个CPU core上的软件控制行为需要传递到其他的CPU上的时候(例如在某一个CPU上运行的进程调用了系统调用进行reboot)，就会调用这个callback函数。对于GIC，这个callback定义为gic_raise_softirq。这个函数名字起的不好，直观上以为是和softirq相关，实际上其实是触发了IPI中断。

(h)在multi processor环境下，当processor状态发送变化的时候(例如online，offline)，需要把这些事件通知到GIC。而GIC driver在收到来自CPU的事件后会对cpu interface进行相应的设定。

3、GIC硬件初始化

(1)Distributor初始化，代码如下：

static void __init gic_dist_init(struct gic_chip_data *gic)

{

unsigned int i;

u32 cpumask;

unsigned int gic_irqs = gic->gic_irqs;－－－－－－－－－获取该GIC支持的IRQ的数目

void __iomem *base = gic_data_dist_base(gic); －－－－获取该GIC对应的Distributor基地址

writel_relaxed(0, base + GIC_DIST_CTRL); －－－－－－－－－－－(a)

cpumask = gic_get_cpumask(gic);－－－－－－－－－－－－－－－(b)

cpumask |= cpumask << 8;

cpumask |= cpumask << 16;－－－－－－－－－－－－－－－－－－(c)

for (i = 32; i < gic_irqs; i += 4)

writel_relaxed(cpumask, base + GIC_DIST_TARGET + i * 4 / 4); －－(d)

gic_dist_config(base, gic_irqs, NULL); －－－－－－－－－－－－－－－(e)

writel_relaxed(1, base + GIC_DIST_CTRL);－－－－－－－－－－－－－(f)

}

(a)Distributor Control Register用来控制全局的中断forward情况。写入0表示Distributor不向CPU interface发送中断请求信号，也就disable了全部的中断请求(group 0和group 1)，CPU interace再也收不到中断请求信号了。在初始化的最后，step(f)那里会进行enable的动作(这里只是enable了group 0的中断)。在初始化代码中，并没有设定interrupt source的group(寄存器是GIC_DIST_IGROUP)，我相信缺省值就是设定为group 0的。

(b)我们先看看gic_get_cpumask的代码：

static u8 gic_get_cpumask(struct gic_chip_data *gic)

{

void __iomem *base = gic_data_dist_base(gic);

u32 mask, i;

for (i = mask = 0; i < 32; i += 4) {

mask = readl_relaxed(base + GIC_DIST_TARGET + i);

mask |= mask >> 16;

mask |= mask >> 8;

if (mask)

break;

}

return mask;

}

这里操作的寄存器是Interrupt Processor Targets Registers，该寄存器组中，每个GIC上的interrupt ID都有8个bit来控制送达的target CPU。我们来看看下面的图片：

![](attachment\7.4.gif)

GIC_DIST_TARGETn(Interrupt Processor Targets Registers)位于Distributor HW block中，能控制送达的CPU interface，并不是具体的CPU，如果具体的实现中CPU interface和CPU是严格按照上图中那样一一对应，那么GIC_DIST_TARGET送达了CPU Interface n，也就是送达了CPU n。当然现实未必如你所愿，那么怎样来获取这个CPU的mask呢?我们知道SGI和PPI不需要使用GIC_DIST_TARGET控制target CPU。SGI送达目标CPU有自己特有的寄存器来控制(Software Generated Interrupt Register)，对于PPI，其是CPU私有的，因此不需要控制target CPU。GIC_DIST_TARGET0~GIC_DIST_TARGET7是控制0~31这32个interrupt ID(SGI和PPI)的target CPU的，但是实际上SGI和PPI是不需要控制target CPU的，因此，这些寄存器是read only的，读取这些寄存器返回的就是cpu mask值。假设CPU0接在CPU interface 4上，那么运行在CPU 0上的程序在读GIC_DIST_TARGET0~GIC_DIST_TARGET7的时候，返回的就是0b00010000。

当然，由于GIC-400只支持8个CPU，因此CPU mask值只需要8bit，但是寄存器GIC_DIST_TARGETn返回32个bit的值，怎么对应?很简单，cpu mask重复四次就OK了。了解了这些知识，回头看代码就很简单了。

(c)step (b)中获取了8个bit的cpu mask值，通过简单的copy，扩充为32个bit，每8个bit都是cpu mask的值，这么做是为了下一步设定所有IRQ(对于GIC而言就是SPI类型的中断)的CPU mask。

(d)设定每个SPI类型的中断都是只送达该CPU。

(e)配置GIC distributor的其他寄存器，代码如下：

void __init gic_dist_config(void __iomem *base, int gic_irqs,  void (*sync_access)(void))

{

unsigned int i;

/* Set all global interrupts to be level triggered, active low.    */

for (i = 32; i < gic_irqs; i += 16)

writel_relaxed(0, base + GIC_DIST_CONFIG + i / 4);

/* Set priority on all global interrupts.   */

for (i = 32; i < gic_irqs; i += 4)

writel_relaxed(0xa0a0a0a0, base + GIC_DIST_PRI + i);

/* Disable all interrupts.  Leave the PPI and SGIs alone as they are enabled by redistributor registers.    */

for (i = 32; i < gic_irqs; i += 32)

writel_relaxed(0xffffffff, base + GIC_DIST_ENABLE_CLEAR + i / 8);

if (sync_access)

sync_access();

}

程序的注释已经非常清楚了，这里就不细述了。需要注意的是：这里设定的都是缺省值，实际上，在各种driver的初始化过程中，还是有可能改动这些设置的(例如触发方式)。

(2)CPU interface初始化，代码如下：

static void gic_cpu_init(struct gic_chip_data *gic)

{

void __iomem *dist_base = gic_data_dist_base(gic);－－－－－－－Distributor的基地址空间

void __iomem *base = gic_data_cpu_base(gic);－－－－－－－CPU interface的基地址空间

unsigned int cpu_mask, cpu = smp_processor_id();－－－－－－获取CPU的逻辑ID

int i;

cpu_mask = gic_get_cpumask(gic);－－－－－－－－－－－－－(a)

gic_cpu_map[cpu] = cpu_mask;

for (i = 0; i < NR_GIC_CPU_IF; i++)

if (i != cpu)

gic_cpu_map[i] &= ~cpu_mask; －－－－－－－－－－－－(b)

gic_cpu_config(dist_base, NULL); －－－－－－－－－－－－－－(c)

writel_relaxed(0xf0, base + GIC_CPU_PRIMASK);－－－－－－－(d)

writel_relaxed(1, base + GIC_CPU_CTRL);－－－－－－－－－－－(e)

}

(a)系统软件实际上是使用CPU 逻辑ID这个概念的，通过smp_processor_id可以获得本CPU的逻辑ID。gic_cpu_map这个全部lookup table就是用CPU 逻辑ID作为所以，去寻找其cpu mask，后续通过cpu mask值来控制中断是否送达该CPU。在gic_init_bases函数中，我们将该lookup table中的值都初始化为0xff，也就是说不进行mask，送达所有的CPU。这里，我们会进行重新修正。

(b)清除lookup table中其他entry中本cpu mask的那个bit。

(c)设定SGI和PPI的初始值。具体代码如下：

void gic_cpu_config(void __iomem *base, void (*sync_access)(void))

{

int i;

/* Deal with the banked PPI and SGI interrupts - disable all

* PPI interrupts, ensure all SGI interrupts are enabled.     */

writel_relaxed(0xffff0000, base + GIC_DIST_ENABLE_CLEAR);

writel_relaxed(0x0000ffff, base + GIC_DIST_ENABLE_SET);

/* Set priority on PPI and SGI interrupts    */

for (i = 0; i < 32; i += 4)

writel_relaxed(0xa0a0a0a0, base + GIC_DIST_PRI + i * 4 / 4);

if (sync_access)

sync_access();

}

程序的注释已经非常清楚了，这里就不细述了。

(d)通过Distributor中的寄存器可以控制送达CPU interface，中断来到了GIC的CPU interface是否可以真正送达CPU呢?也不一定，还有一道关卡，也就是CPU interface中的Interrupt Priority Mask Register。这个寄存器设定了一个中断优先级的值，只有中断优先级高过该值的中断请求才会被送到CPU上去。我们在前面初始化的时候，给每个interrupt ID设定的缺省优先级是0xa0，这里设定的priority filter的优先级值是0xf0。数值越小，优先级越过。因此，这样的设定就是让所有的interrupt source都可以送达CPU，在CPU interface这里不做控制了。

(e)设定CPU interface的control register。enable了group 0的中断，disable了group 1的中断，group 0的interrupt source触发IRQ中断(而不是FIQ中断)。

(3)GIC电源管理初始化，代码如下：

static void __init gic_pm_init(struct gic_chip_data *gic)

{

gic->saved_ppi_enable = __alloc_percpu(DIV_ROUND_UP(32, 32) * 4, sizeof(u32));

gic->saved_ppi_conf = __alloc_percpu(DIV_ROUND_UP(32, 16) * 4,  sizeof(u32));

if (gic == &gic_data[0])

cpu_pm_register_notifier(&gic_notifier_block);

}

这段代码前面主要是分配两个per cpu的内存。这些内存在系统进入sleep状态的时候保存PPI的寄存器状态信息，在resume的时候，写回寄存器。对于root GIC，需要注册一个和电源管理的事件通知callback函数。不得不吐槽一下gic_notifier_block和gic_notifier这两个符号的命名，看不出来和电源管理有任何关系。更优雅的名字应该包括pm这样的符号，以便让其他工程师看到名字就立刻知道是和电源管理相关的。

四、GIC callback函数分析

1、irq domain相关callback函数分析

irq domain相关callback函数包括：

(1)gic_irq_domain_map函数：创建IRQ number和GIC hw interrupt ID之间映射关系的时候，需要调用该回调函数。具体代码如下：

static int gic_irq_domain_map(struct irq_domain *d, unsigned int irq, irq_hw_number_t hw)

{

if (hw < 32) {－－－－－－－－－－－－－－－－－－SGI或者PPI

irq_set_percpu_devid(irq);－－－－－－－－－－－－－－－－－－－－－－－－－－(a)

irq_set_chip_and_handler(irq, &gic_chip, handle_percpu_devid_irq);－－－－－－－(b)

set_irq_flags(irq, IRQF_VALID | IRQF_NOAUTOEN);－－－－－－－－－－－－－－(c)

} else {

irq_set_chip_and_handler(irq, &gic_chip, handle_fasteoi_irq);－－－－－－－－－－(d)

set_irq_flags(irq, IRQF_VALID | IRQF_PROBE);

gic_routable_irq_domain_ops->map(d, irq, hw);－－－－－－－－－－－－－－－－(e)

}

irq_set_chip_data(irq, d->host_data);－－－－－设定irq chip的私有数据

return 0;

}

(a)SGI或者PPI和SPI最大的不同是per cpu的，SPI是所有CPU共享的，因此需要分配per cpu的内存，设定一些per cpu的flag。

(b)设定该中断描述符的irq chip和high level的handler

(c)设定irq flag是有效的(因为已经设定好了chip和handler了)，并且request后不是auto enable的。

(d)对于SPI，设定的high level irq event handler是handle_fasteoi_irq。对于SPI，是可以probe，并且request后是auto enable的。

(e)有些SOC会在各种外设中断和GIC之间增加cross bar(例如TI的OMAP芯片)，这里是为那些ARM SOC准备的

(2)gic_irq_domain_unmap是gic_irq_domain_map的逆过程也就是解除IRQ number和GIC hw interrupt ID之间映射关系的时候，需要调用该回调函数。

(3)gic_irq_domain_xlate函数：除了标准的属性之外，各个具体的interrupt controller可以定义自己的device binding。这些device bindings都需在irq chip driver这个层面进行解析。要给定某个外设的device tree node 和interrupt specifier，该函数可以解码出该设备使用的hw interrupt ID和linux irq type value 。具体的代码如下：

static int gic_irq_domain_xlate(struct irq_domain *d,

struct device_node *controller,

const u32 *intspec, unsigned int intsize,－－－－－－－－输入参数

unsigned long *out_hwirq, unsigned int *out_type)－－－－输出参数

{

unsigned long ret = 0;

*out_hwirq = intspec[1] + 16; －－－－－－－－－－－－－－－－－－－－－(a)

*out_type = intspec[2] & IRQ_TYPE_SENSE_MASK; －－－－－－－－－－－(b)

return ret;

}

(a)根据gic binding文档的描述，其interrupt specifier包括3个cell，分别是interrupt type(0 表示SPI，1表示PPI)，interrupt number(对于PPI，范围是[0-15]，对于SPI，范围是[0-987])，interrupt flag(触发方式)。GIC interrupt specifier中的interrupt number需要加上16(也就是加上SGI的那些ID号)，才能转换成GIC的HW interrupt ID。

(b)取出bits[3:0]的信息，这些bits保存了触发方式的信息

2、电源管理的callback函数

TODO

3、irq chip回调函数分析

(1)gic_mask_irq函数

这个函数用来mask一个interrupt source。代码如下：

static void gic_mask_irq(struct irq_data *d)

{

u32 mask = 1 << (gic_irq(d) % 32);

raw_spin_lock(&irq_controller_lock);

writel_relaxed(mask, gic_dist_base(d) + GIC_DIST_ENABLE_CLEAR + (gic_irq(d) / 32) * 4);

if (gic_arch_extn.irq_mask)

gic_arch_extn.irq_mask(d);

raw_spin_unlock(&irq_controller_lock);

}

GIC有若干个叫做Interrupt Clear-Enable Registers(具体数目是和GIC支持的hw interrupt数目相关，我们前面说过的，GIC是一个高度可配置的interrupt controller)。这些Interrupt Clear-Enable Registers寄存器的每个bit可以控制一个interrupt source是否forward到CPU interface，写入1表示Distributor不再forward该interrupt，因此CPU也就感知不到该中断，也就是mask了该中断。特别需要注意的是：写入0无效，而不是unmask的操作。

由于不同的SOC厂商在集成GIC的时候可能会修改，也就是说，也有可能mask的代码要微调，这是通过gic_arch_extn这个全局变量实现的。在gic-irq.c中这个变量的全部成员都设定为NULL，各个厂商在初始中断控制器的时候可以设定其特定的操作函数。

(2)gic_unmask_irq函数

这个函数用来unmask一个interrupt source。代码如下：

static void gic_unmask_irq(struct irq_data *d)

{

u32 mask = 1 << (gic_irq(d) % 32);

raw_spin_lock(&irq_controller_lock);

if (gic_arch_extn.irq_unmask)

gic_arch_extn.irq_unmask(d);

writel_relaxed(mask, gic_dist_base(d) + GIC_DIST_ENABLE_SET + (gic_irq(d) / 32) * 4);

raw_spin_unlock(&irq_controller_lock);

}

GIC有若干个叫做Interrupt Set-Enable Registers的寄存器。这些寄存器的每个bit可以控制一个interrupt source。当写入1的时候，表示Distributor会forward该interrupt到CPU interface，也就是意味这unmask了该中断。特别需要注意的是：写入0无效，而不是mask的操作。

(3)gic_eoi_irq函数

当processor处理中断的时候就会调用这个函数用来结束中断处理。代码如下：

static void gic_eoi_irq(struct irq_data *d)

{

if (gic_arch_extn.irq_eoi) {

raw_spin_lock(&irq_controller_lock);

gic_arch_extn.irq_eoi(d);

raw_spin_unlock(&irq_controller_lock);

}

writel_relaxed(gic_irq(d), gic_cpu_base(d) + GIC_CPU_EOI);

}

对于GIC而言，其中断状态有四种：



| 中断状态               | 描述                                       |
| ------------------ | ---------------------------------------- |
| Inactive           | 中断未触发状态，该中断即没有Pending也没有Active           |
| Pending            | 由于外设硬件产生了中断事件(或者软件触发)该中断事件已经通过硬件信号通知到GIC，等待GIC分配的那个CPU进行处理 |
| Active             | CPU已经应答(acknowledge)了该interrupt请求，并且正在处理中 |
| Active and Pending | 当一个中断源处于Active状态的时候，同一中断源又触发了中断，进入pending状态 |


processor ack了一个中断后，该中断会被设定为active。当处理完成后，仍然要通知GIC，中断已经处理完毕了。这时候，如果没有pending的中断，GIC就会将该interrupt设定为inactive状态。操作GIC中的End of Interrupt Register可以完成end of interrupt事件通知。

(4)gic_set_type函数

这个函数用来设定一个interrupt source的type，例如是level sensitive还是edge triggered。代码如下：

static int gic_set_type(struct irq_data *d, unsigned int type)

{

void __iomem *base = gic_dist_base(d);

unsigned int gicirq = gic_irq(d);

u32 enablemask = 1 << (gicirq % 32);

u32 enableoff = (gicirq / 32) * 4;

u32 confmask = 0x2 << ((gicirq % 16) * 2);

u32 confoff = (gicirq / 16) * 4;

bool enabled = false;

u32 val;

/* Interrupt configuration for SGIs can't be changed */

if (gicirq < 16)

return -EINVAL;

if (type != IRQ_TYPE_LEVEL_HIGH && type != IRQ_TYPE_EDGE_RISING)

return -EINVAL;

raw_spin_lock(&irq_controller_lock);

if (gic_arch_extn.irq_set_type)

gic_arch_extn.irq_set_type(d, type);

val = readl_relaxed(base + GIC_DIST_CONFIG + confoff);

if (type == IRQ_TYPE_LEVEL_HIGH)

val &= ~confmask;

else if (type == IRQ_TYPE_EDGE_RISING)

val |= confmask;

/*

* As recommended by the spec, disable the interrupt before changing

* the configuration

*/

if (readl_relaxed(base + GIC_DIST_ENABLE_SET + enableoff) & enablemask) {

writel_relaxed(enablemask, base + GIC_DIST_ENABLE_CLEAR + enableoff);

enabled = true;

}

writel_relaxed(val, base + GIC_DIST_CONFIG + confoff);

if (enabled)

writel_relaxed(enablemask, base + GIC_DIST_ENABLE_SET + enableoff);

raw_spin_unlock(&irq_controller_lock);

return 0;

}

对于SGI类型的interrupt，是不能修改其type的，因为GIC中SGI固定就是edge-triggered。对于GIC，其type只支持高电平触发(IRQ_TYPE_LEVEL_HIGH)和上升沿触发(IRQ_TYPE_EDGE_RISING)的中断。另外需要注意的是，在更改其type的时候，先disable，然后修改type，然后再enable。

(5)gic_retrigger

这个接口用来resend一个IRQ到CPU。

static int gic_retrigger(struct irq_data *d)

{

if (gic_arch_extn.irq_retrigger)

return gic_arch_extn.irq_retrigger(d);

/* the genirq layer expects 0 if we can't retrigger in hardware */

return 0;

}

看起来这是功能不是通用GIC拥有的功能，各个厂家在集成GIC的时候，有可能进行功能扩展。

(6)gic_set_affinity

在多处理器的环境下，外部设备产生了一个中断就需要送到一个或者多个处理器去，这个设定是通过设定处理器的affinity进行的。具体代码如下：

static int gic_set_affinity(struct irq_data *d, const struct cpumask *mask_val,    bool force)

{

void __iomem *reg = gic_dist_base(d) + GIC_DIST_TARGET + (gic_irq(d) & ~3);

unsigned int cpu, shift = (gic_irq(d) % 4) * 8;

u32 val, mask, bit;

if (!force)

cpu = cpumask_any_and(mask_val, cpu_online_mask);－－－随机选取一个online的cpu

else

cpu = cpumask_first(mask_val); －－－－－－－－选取mask中的第一个cpu，不管是否online

raw_spin_lock(&irq_controller_lock);

mask = 0xff << shift;

bit = gic_cpu_map[cpu] << shift;－－－－－－－将CPU的逻辑ID转换成要设定的cpu mask

val = readl_relaxed(reg) & ~mask;

writel_relaxed(val | bit, reg);

raw_spin_unlock(&irq_controller_lock);

return IRQ_SET_MASK_OK;

}

GIC Distributor中有一个寄存器叫做Interrupt Processor Targets Registers，这个寄存器用来设定制定的中断送到哪个process去。由于GIC最大支持8个process，因此每个hw interrupt ID需要8个bit来表示送达的process。每一个Interrupt Processor Targets Registers由32个bit组成，因此每个Interrupt Processor Targets Registers可以表示4个HW interrupt ID的affinity，因此上面的代码中的shift就是计算该HW interrupt ID在寄存器中的偏移。

(7)gic_set_wake

这个接口用来设定唤醒CPU的interrupt source。对于GIC，代码如下：

static int gic_set_wake(struct irq_data *d, unsigned int on)

{

int ret = -ENXIO;

if (gic_arch_extn.irq_set_wake)

ret = gic_arch_extn.irq_set_wake(d, on);

return ret;

}

设定唤醒的interrupt和具体的厂商相关，这里不再赘述。

4、BSP(bootstrap processor)之外，其他CPU的callback函数

对于multi processor系统，不可能初始化代码在所有的processor上都执行一遍，实际上，系统的硬件会选取一个processor作为引导处理器，我们称之BSP。这个processor会首先执行，其他的CPU都是处于reset状态，等到BSP初始化完成之后，release所有的non-BSP，这时候，系统中的各种外设硬件条件和软件条件(例如per CPU变量)都准备好了，各个non-BSP执行自己CPU specific的初始化就OK了。

上面描述的都是BSP的初始化过程，具体包括：

……

gic_dist_init(gic);－－－－－－初始化GIC的Distributor

gic_cpu_init(gic);－－－－－－初始化BSP的CPU interface

gic_pm_init(gic);－－－－－－初始化GIC的Power management

……

对于GIC的Distributor和Power management，这两部分是全局性的，BSP执行初始化一次就OK了。对于CPU interface，每个processor负责初始化自己的连接的那个CPU interface HW block。我们用下面这个图片来描述这个过程：

![](attachment\7.5.gif)

假设CPUx被选定为BSP，那么第三章描述的初始化过程在该CPU上欢畅的执行。这时候，被初始化的GIC硬件包括：root GIC的Distributor、root GIC CPU Interface x(连接BSP的那个CPU interface)以及其他的级联的非root GIC(上图中绿色block，当然，我偷懒，没有画non-root GIC)。

BSP初始化完成之后，各个其他的CPU运行起来，会发送CPU_STARTING消息给关注该消息的模块。毫无疑问，GIC driver模块当然要关注这样的消息，在初始化过程中会注册callback函数如下：

register_cpu_notifier(&gic_cpu_notifier);

GIC相关的回调函数定义如下：

static struct notifier_block gic_cpu_notifier = {

.notifier_call = gic_secondary_init,

.priority = 100,

};

static int gic_secondary_init(struct notifier_block *nfb, unsigned long action,  void *hcpu)

{

if (action == CPU_STARTING || action == CPU_STARTING_FROZEN)

gic_cpu_init(&gic_data[0]);－－－－－－－－－初始化那些非BSP的CPU interface

return NOTIFY_OK;

}

因此，当non-BSP booting up的时候，发送CPU_STARTING消息，调用GIC的callback函数，对上图中的紫色的CPU Interface HW block进行初始化，这样，就完成了全部GIC硬件的初始化过程。

Change log：

11月3号，修改包括：

1、使用GIC-V2这样更通用的描述，而不是仅仅GIC-400




## (八)：softirq

一、前言

对于中断处理而言，linux将其分成了两个部分，一个叫做中断handler(top half)，是全程关闭中断的，另外一部分是deferable task(bottom half)，属于不那么紧急需要处理的事情。在执行bottom half的时候，是开中断的。有多种bottom half的机制，例如：softirq、tasklet、workqueue或是直接创建一个kernel thread来执行bottom half(这在旧的kernel驱动中常见，现在，一个理智的driver厂商是不会这么做的)。本文主要讨论softirq机制。由于tasklet是基于softirq的，因此本文也会提及tasklet，但主要是从需求层面考虑，不会涉及其具体的代码实现。

在普通的驱动中一般是不会用到softirq，但是由于驱动经常使用的tasklet是基于softirq的，因此，了解softirq机制有助于撰写更优雅的driver。softirq不能动态分配，都是静态定义的。内核已经定义了若干种softirq number，例如网络数据的收发、block设备的数据访问(数据量大，通信带宽高)，timer的deferable task(时间方面要求高)。本文的第二章讨论了softirq和tasklet这两种机制有何不同，分别适用于什么样的场景。第三章描述了一些context的概念，这是要理解后续内容的基础。第四章是进入softirq的实现，对比hard irq来解析soft irq的注册、触发，调度的过程。

注：本文中的linux kernel的版本是3.14

二、为何有softirq和tasklet

1、为何有top half和bottom half

中断处理模块是任何OS中最重要的一个模块，对系统的性能会有直接的影响。想像一下：如果在通过U盘进行大量数据拷贝的时候，你按下一个key，需要半秒的时间才显示出来，这个场景是否让你崩溃?因此，对于那些复杂的、需要大量数据处理的硬件中断，我们不能让handler中处理完一切再恢复现场(handler是全程关闭中断的)，而是仅仅在handler中处理一部分，具体包括：

(1)有实时性要求的

(2)和硬件相关的。例如ack中断，read HW FIFO to ram等

(3)如果是共享中断，那么获取硬件中断状态以便判断是否是本中断发生

除此之外，其他的内容都是放到bottom half中处理。在把中断处理过程划分成top half和bottom half之后，关中断的top half被瘦身，可以非常快速的执行完毕，大大减少了系统关中断的时间，提高了系统的性能。

我们可以基于下面的系统进一步的进行讨论：

![](attachment\8.1.gif)

当网卡控制器的FIFO收到的来自以太网的数据的时候(例如半满的时候，可以软件设定)，可以将该事件通过irq signal送达Interrupt Controller。Interrupt Controller可以把中断分发给系统中的Processor A or B。

NIC的中断处理过程大概包括：mask and ack interrupt controller-------->ack NIC-------->copy FIFO to ram------>handle Data in the ram----------->unmask interrupt controller

我们先假设Processor A处理了这个网卡中断事件，于是NIC的中断handler在Processor A上欢快的执行，这时候，Processor A的本地中断是disable的。NIC的中断handler在执行的过程中，网络数据仍然源源不断的到来，但是，如果NIC的中断handler不操作NIC的寄存器来ack这个中断的话，NIC是不会触发下一次中断的。还好，我们的NIC interrupt handler总是在最开始就会ack，因此，这不会导致性能问题。ack之后，NIC已经具体再次trigger中断的能力。当Processor A上的handler 在处理接收来自网络的数据的时候，NIC的FIFO很可能又收到新的数据，并trigger了中断，这时候，Interrupt controller还没有umask，因此，即便还有Processor B(也就是说有处理器资源)，中断控制器也无法把这个中断送达处理器系统。因此，只能眼睁睁的看着NIC FIFO填满数据，数据溢出，或者向对端发出拥塞信号，无论如何，整体的系统性能是受到严重的影响。

注意：对于新的interrupt controller，可能没有mask和umask操作，但是原理是一样的，只不过NIC的handler执行完毕要发生EOI而已。

要解决上面的问题，最重要的是尽快的执行完中断handler，打开中断，unmask IRQ(或者发送EOI)，方法就是把耗时的handle Data in the ram这个步骤踢出handler，让其在bottom half中执行。

2、为何有softirq和tasklet

OK，linux kernel已经把中断处理分成了top half和bottom half，看起来已经不错了，那为何还要提供softirq、tasklet和workqueue这些bottom half机制，linux kernel本来就够复杂了，bottom half还来添乱。实际上，在早期的linux kernel还真是只有一个bottom half机制，简称BH，简单好用，但是性能不佳。后来，linux kernel的开发者开发了task queue机制，试图来替代BH，当然，最后task queue也消失在内核代码中了。现在的linux kernel提供了三种bottom half的机制，来应对不同的需求。

workqueue和softirq、tasklet有本质的区别：workqueue运行在process context，而softirq和tasklet运行在interrupt context。因此，出现workqueue是不奇怪的，在有sleep需求的场景中，defering task必须延迟到kernel thread中执行，也就是说必须使用workqueue机制。softirq和tasklet是怎么回事呢?从本质上将，bottom half机制的设计有两方面的需求，一个是性能，一个是易用性。设计一个通用的bottom half机制来满足这两个需求非常的困难，因此，内核提供了softirq和tasklet两种机制。softirq更倾向于性能，而tasklet更倾向于易用性。

我们还是进入实际的例子吧，还是使用上一节的系统图。在引入softirq之后，网络数据的处理如下：

关中断：mask and ack interrupt controller-------->ack NIC-------->copy FIFO to ram------>raise softirq------>unmask interrupt controller

开中断：在softirq上下文中进行handle Data in the ram的动作

同样的，我们先假设Processor A处理了这个网卡中断事件，很快的完成了基本的HW操作后，raise softirq。在返回中断现场前，会检查softirq的触发情况，因此，后续网络数据处理的softirq在processor A上执行。在执行过程中，NIC硬件再次触发中断，Interrupt controller将该中断分发给processor B，执行动作和Processor A是类似的，因此，最后，网络数据处理的softirq在processor B上执行。

为了性能，同一类型的softirq有可能在不同的CPU上并发执行，这给使用者带来了极大的痛苦，因为驱动工程师在撰写softirq的回调函数的时候要考虑重入，考虑并发，要引入同步机制。但是，为了性能，我们必须如此。

当网络数据处理的softirq同时在Processor A和B上运行的时候，网卡中断又来了(可能是10G的网卡吧)。这时候，中断分发给processor A，这时候，processor A上的handler仍然会raise softirq，但是并不会调度该softirq。也就是说，softirq在一个CPU上是串行执行的。这种情况下，系统性能瓶颈是CPU资源，需要增加更多的CPU来解决该问题。

如果是tasklet的情况会如何呢?为何tasklet性能不如softirq呢?如果一个tasklet在processor A上被调度执行，那么它永远也不会同时在processor B上执行，也就是说，tasklet是串行执行的(注：不同的tasklet还是会并发的)，不需要考虑重入的问题。我们还是用网卡这个例子吧(注意：这个例子仅仅是用来对比，实际上，网络数据是使用softirq机制的)，同样是上面的系统结构图。假设使用tasklet，网络数据的处理如下：

关中断：mask and ack interrupt controller-------->ack NIC-------->copy FIFO to ram------>schedule tasklet------>unmask interrupt controller

开中断：在softirq上下文中(一般使用TASKLET_SOFTIRQ这个softirq)进行handle Data in the ram的动作

同样的，我们先假设Processor A处理了这个网卡中断事件，很快的完成了基本的HW操作后，schedule tasklet(同时也就raise TASKLET_SOFTIRQ softirq)。在返回中断现场前，会检查softirq的触发情况，因此，在TASKLET_SOFTIRQ softirq的handler中，获取tasklet相关信息并在processor A上执行该tasklet的handler。在执行过程中，NIC硬件再次触发中断，Interrupt controller将该中断分发给processor B，执行动作和Processor A是类似的，虽然TASKLET_SOFTIRQ softirq在processor B上可以执行，但是，在检查tasklet的状态的时候，如果发现该tasklet在其他processor上已经正在运行，那么该tasklet不会被处理，一直等到在processor A上的tasklet处理完，在processor B上的这个tasklet才能被执行。这样的串行化操作虽然对驱动工程师是一个福利，但是对性能而言是极大的损伤。

三、理解softirq需要的基础知识(各种context)

1、preempt_count

为了更好的理解下面的内容，我们需要先看看一些基础知识：一个task的thread info数据结构定义如下(只保留和本场景相关的内容)：

struct thread_info {

……

int            preempt_count;    /* 0 => preemptable, <0 => bug */

……

};

preempt_count这个成员被用来判断当前进程是否可以被抢占。如果preempt_count不等于0(可能是代码调用preempt_disable显式的禁止了抢占，也可能是处于中断上下文等)，说明当前不能进行抢占，如果preempt_count等于0，说明已经具备了抢占的条件(当然具体是否要抢占当前进程还是要看看thread info中的flag成员是否设定了_TIF_NEED_RESCHED这个标记，可能是当前的进程的时间片用完了，也可能是由于中断唤醒了优先级更高的进程)。 具体preempt_count的数据格式可以参考下图：

![](attachment\8.2.gif)

preemption count用来记录当前被显式的禁止抢占的次数，也就是说，每调用一次preempt_disable，preemption count就会加一，调用preempt_enable，该区域的数值会减去一。preempt_disable和preempt_enable必须成对出现，可以嵌套，最大嵌套的深度是255。

hardirq count描述当前中断handler嵌套的深度。对于ARM平台的linux kernel，其中断部分的代码如下：

void handle_IRQ(unsigned int irq, struct pt_regs *regs)

{

struct pt_regs *old_regs = set_irq_regs(regs);

irq_enter();

generic_handle_irq(irq);

irq_exit();

set_irq_regs(old_regs);

}

通用的IRQ handler被irq_enter和irq_exit这两个函数包围。irq_enter说明进入到IRQ context，而irq_exit则说明退出IRQ context。在irq_enter函数中会调用preempt_count_add(HARDIRQ_OFFSET)，为hardirq count的bit field增加1。在irq_exit函数中，会调用preempt_count_sub(HARDIRQ_OFFSET)，为hardirq count的bit field减去1。hardirq count占用了4个bit，说明硬件中断handler最大可以嵌套15层。在旧的内核中，hardirq count占用了12个bit，支持4096个嵌套。当然，在旧的kernel中还区分fast interrupt handler和slow interrupt handler，中断handler最大可以嵌套的次数理论上等于系统IRQ的个数。在实际中，这个数目不可能那么大(内核栈就受不了)，因此，即使系统支持了非常大的中断个数，也不可能各个中断依次嵌套，达到理论的上限。基于这样的考虑，后来内核减少了hardirq count占用bit数目，改成了10个bit(在general arch的代码中修改为10，实际上，各个arch可以redefine自己的hardirq count的bit数)。但是，当内核大佬们决定废弃slow interrupt handler的时候，实际上，中断的嵌套已经不会发生了。因此，理论上，hardirq count要么是0，要么是1。不过呢，不能总拿理论说事，实际上，万一有写奇葩或者老古董driver在handler中打开中断，那么这时候中断嵌套还是会发生的，但是，应该不会太多(一个系统中怎么可能有那么多奇葩呢?呵呵)，因此，目前hardirq count占用了4个bit，应付15个奇葩driver是妥妥的。

对softirq count进行操作有两个场景：

(1)也是在进入soft irq handler之前给 softirq count加一，退出soft irq handler之后给 softirq count减去一。由于soft irq handler在一个CPU上是不会并发的，总是串行执行，因此，这个场景下只需要一个bit就够了，也就是上图中的bit 8。通过该bit可以知道当前task是否在sofirq context。

(2)由于内核同步的需求，进程上下文需要禁止softirq。这时候，kernel提供了local_bh_enable和local_bh_disable这样的接口函数。这部分的概念是和preempt disable/enable类似的，占用了bit9~15，最大可以支持127次嵌套。

2、一个task的各种上下文

看完了preempt_count之后，我们来介绍各种context：

#define in_irq()        (hardirq_count())

#define in_softirq()        (softirq_count())

#define in_interrupt()        (irq_count())

#define in_serving_softirq()    (softirq_count() & SOFTIRQ_OFFSET)

这里首先要介绍的是一个叫做IRQ context的术语。这里的IRQ context其实就是hard irq context，也就是说明当前正在执行中断handler(top half)，只要preempt_count中的hardirq count大于0(=1是没有中断嵌套，如果大于1，说明有中断嵌套)，那么就是IRQ context。

softirq context并没有那么的直接，一般人会认为当sofirq handler正在执行的时候就是softirq context。这样说当然没有错，sofirq handler正在执行的时候，会增加softirq count，当然是softirq context。不过，在其他context的情况下，例如进程上下文中，有有可能因为同步的要求而调用local_bh_disable，这时候，通过local_bh_disable/enable保护起来的代码也是执行在softirq context中。当然，这时候其实并没有正在执行softirq handler。如果你确实想知道当前是否正在执行softirq handler，in_serving_softirq可以完成这个使命，这是通过操作preempt_count的bit 8来完成的。

所谓中断上下文，就是IRQ context + softirq context+NMI context。

四、softirq机制

softirq和hardirq(就是硬件中断啦)是对应的，因此softirq的机制可以参考hardirq对应理解，当然softirq是纯软件的，不需要硬件参与。

1、softirq number

和IRQ number一样，对于软中断，linux kernel也是用一个softirq number唯一标识一个softirq，具体定义如下：

enum

{

HI_SOFTIRQ=0,

TIMER_SOFTIRQ,

NET_TX_SOFTIRQ,

NET_RX_SOFTIRQ,

BLOCK_SOFTIRQ,

BLOCK_IOPOLL_SOFTIRQ,

TASKLET_SOFTIRQ,

SCHED_SOFTIRQ,

HRTIMER_SOFTIRQ,

RCU_SOFTIRQ,    /* Preferable RCU should always be the last softirq */

NR_SOFTIRQS

};

HI_SOFTIRQ用于高优先级的tasklet，TASKLET_SOFTIRQ用于普通的tasklet。TIMER_SOFTIRQ是for software timer的(所谓software timer就是说该timer是基于系统tick的)。NET_TX_SOFTIRQ和NET_RX_SOFTIRQ是用于网卡数据收发的。BLOCK_SOFTIRQ和BLOCK_IOPOLL_SOFTIRQ是用于block device的。SCHED_SOFTIRQ用于多CPU之间的负载均衡的。HRTIMER_SOFTIRQ用于高精度timer的。RCU_SOFTIRQ是处理RCU的。这些具体使用情景分析会在各自的子系统中分析，本文只是描述softirq的工作原理。

2、softirq描述符

我们前面已经说了，softirq是静态定义的，也就是说系统中有一个定义softirq描述符的数组，而softirq number就是这个数组的index。这个概念和早期的静态分配的中断描述符概念是类似的。具体定义如下：

struct softirq_action

{

void    (*action)(struct softirq_action *);

};

static struct softirq_action softirq_vec[NR_SOFTIRQS] __cacheline_aligned_in_smp;

系统支持多少个软中断，静态定义的数组就会有多少个entry。____cacheline_aligned保证了在SMP的情况下，softirq_vec是对齐到cache line的。softirq描述符非常简单，只有一个action成员，表示如果触发了该softirq，那么应该调用action回调函数来处理这个soft irq。对于硬件中断而言，其mask、ack等都是和硬件寄存器相关并封装在irq chip函数中，对于softirq，没有硬件寄存器，只有“软件寄存器”，定义如下：

typedef struct {

unsigned int __softirq_pending;

#ifdef CONFIG_SMP

unsigned int ipi_irqs[NR_IPI];

#endif

} ____cacheline_aligned irq_cpustat_t;

irq_cpustat_t irq_stat[NR_CPUS] ____cacheline_aligned;

ipi_irqs这个成员用于处理器之间的中断，我们留到下一个专题来描述。__softirq_pending就是这个“软件寄存器”。softirq采用谁触发，谁负责处理的。例如：当一个驱动的硬件中断被分发给了指定的CPU，并且在该中断handler中触发了一个softirq，那么该CPU负责调用该softirq number对应的action callback来处理该软中断。因此，这个“软件寄存器”应该是每个CPU拥有一个(专业术语叫做banked register)。为了性能，irq_stat中的每一个entry被定义对齐到cache line。

3、如何注册一个softirq

通过调用open_softirq接口函数可以注册softirq的action callback函数，具体如下：

void open_softirq(int nr, void (*action)(struct softirq_action *))

{

softirq_vec[nr].action = action;

}

softirq_vec是一个多CPU之间共享的数据，不过，由于所有的注册都是在系统初始化的时候完成的，那时候，系统是串行执行的。此外，softirq是静态定义的，每个entry(或者说每个softirq number)都是固定分配的，因此，不需要保护。

4、如何触发softirq?

在linux kernel中，可以调用raise_softirq这个接口函数来触发本地CPU上的softirq，具体如下：

void raise_softirq(unsigned int nr)

{

unsigned long flags;

local_irq_save(flags);

raise_softirq_irqoff(nr);

local_irq_restore(flags);

}

虽然大部分的使用场景都是在中断handler中(也就是说关闭本地CPU中断)来执行softirq的触发动作，但是，这不是全部，在其他的上下文中也可以调用raise_softirq。因此，触发softirq的接口函数有两个版本，一个是raise_softirq，有关中断的保护，另外一个是raise_softirq_irqoff，调用者已经关闭了中断，不需要关中断来保护“soft irq status register”。

所谓trigger softirq，就是在__softirq_pending(也就是上面说的soft irq status register)的某个bit置一。从上面的定义可知，__softirq_pending是per cpu的，因此不需要考虑多个CPU的并发，只要disable本地中断，就可以确保对，__softirq_pending操作的原子性。

具体raise_softirq_irqoff的代码如下：

inline void raise_softirq_irqoff(unsigned int nr)

{

__raise_softirq_irqoff(nr); －－－－－－－－－－－－－－－－(1)

if (!in_interrupt())

wakeup_softirqd();－－－－－－－－－－－－－－－－－－(2)

}

(1)__raise_softirq_irqoff函数设定本CPU上的__softirq_pending的某个bit等于1，具体的bit是由soft irq number(nr参数)指定的。

(2)如果在中断上下文，我们只要set __softirq_pending的某个bit就OK了，在中断返回的时候自然会进行软中断的处理。但是，如果在context上下文调用这个函数的时候，我们必须要调用wakeup_softirqd函数用来唤醒本CPU上的softirqd这个内核线程。具体softirqd的内容请参考下一个章节。

5、disable/enable softirq

在linux kernel中，可以使用local_irq_disable和local_irq_enable来disable和enable本CPU中断。和硬件中断一样，软中断也可以disable，接口函数是local_bh_disable和local_bh_enable。虽然和想像的local_softirq_enable/disable有些出入，不过bh这个名字更准确反应了该接口函数的意涵，因为local_bh_disable/enable函数就是用来disable/enable bottom half的，这里就包括softirq和tasklet。

先看disable吧，毕竟禁止bottom half比较简单：

static inline void local_bh_disable(void)

{

__local_bh_disable_ip(_THIS_IP_, SOFTIRQ_DISABLE_OFFSET);

}

static __always_inline void __local_bh_disable_ip(unsigned long ip, unsigned int cnt)

{

preempt_count_add(cnt);

barrier();

}

看起来disable bottom half比较简单，就是讲current thread info上的preempt_count成员中的softirq count的bit field9~15加上一就OK了。barrier是优化屏障(Optimization barrier)，会在内核同步系列文章中描述。

enable函数比较复杂，如下：

static inline void local_bh_enable(void)

{

__local_bh_enable_ip(_THIS_IP_, SOFTIRQ_DISABLE_OFFSET);

}

void __local_bh_enable_ip(unsigned long ip, unsigned int cnt)

{

WARN_ON_ONCE(in_irq() || irqs_disabled());－－－－－－－－－－－(1)

preempt_count_sub(cnt - 1); －－－－－－－－－－－－－－－－－－(2)

if (unlikely(!in_interrupt() && local_softirq_pending())) { －－－－－－－(3)

do_softirq();

}

preempt_count_dec(); －－－－－－－－－－－－－－－－－－－－－(4)

preempt_check_resched();

}

(1)disable/enable bottom half是一种内核同步机制。在硬件中断的handler(top half)中，不应该调用disable/enable bottom half函数来保护共享数据，因为bottom half其实是不可能抢占top half的。同样的，soft irq也不会抢占另外一个soft irq的执行，也就是说，一旦一个softirq handler被调度执行(无论在哪一个processor上)，那么，本地的softirq handler都无法抢占其运行，要等到当前的softirq handler运行完毕后，才能执行下一个soft irq handler。注意：上面我们说的是本地，是local，softirq handler是可以在多个CPU上同时运行的，但是，linux kernel中没有disable all softirq的接口函数(就好像没有disable all CPU interrupt的接口一样，注意体会local_bh_enable/disable中的local的含义)。

说了这么多，一言以蔽之，local_bh_enable/disable是给进程上下文使用的，用于防止softirq handler抢占local_bh_enable/disable之间的临界区的。

irqs_disabled接口函数可以获知当前本地CPU中断是否是disable的，如果返回1，那么当前是disable 本地CPU的中断的。如果irqs_disabled返回1，有可能是下面这样的代码造成的：

local_irq_disable();

……

local_bh_disable();

……

local_bh_enable();

……

local_irq_enable();

本质上，关本地中断是一种比关本地bottom half更强劲的锁，关本地中断实际上是禁止了top half和bottom half抢占当前进程上下文的运行。也许你会说：这也没有什么，就是有些浪费，至少代码逻辑没有问题。但事情没有这么简单，在local_bh_enable--->do_softirq--->__do_softirq中，有一条无条件打开当前中断的操作，也就是说，原本想通过local_irq_disable/local_irq_enable保护的临界区被破坏了，其他的中断handler可以插入执行，从而无法保证local_irq_disable/local_irq_enable保护的临界区的原子性，从而破坏了代码逻辑。

in_irq()这个函数如果不等于0的话，说明local_bh_enable被irq_enter和irq_exit包围，也就是说在中断handler中调用了local_bh_enable/disable。这道理是和上面类似的，这里就不再详细描述了。

(2)在local_bh_disable中我们为preempt_count增加了SOFTIRQ_DISABLE_OFFSET，在local_bh_enable函数中应该减掉同样的数值。这一步，我们首先减去了(SOFTIRQ_DISABLE_OFFSET－1)，为何不一次性的减去SOFTIRQ_DISABLE_OFFSET呢?考虑下面运行在进程上下文的代码场景：

……

local_bh_disable

……需要被保护的临界区……

local_bh_enable

……

在临界区内，有进程context 和softirq共享的数据，因此，在进程上下文中使用local_bh_enable/disable进行保护。假设在临界区代码执行的时候，发生了中断，由于代码并没有阻止top half的抢占，因此中断handler会抢占当前正在执行的thread。在中断handler中，我们raise了softirq，在返回中断现场的时候，由于disable了bottom half，因此虽然触发了softirq，但是不会调度执行。因此，代码返回临界区继续执行，直到local_bh_enable。一旦enable了bottom half，那么之前raise的softirq就需要调度执行了，因此，这也是为什么在local_bh_enable会调用do_softirq函数。

调用do_softirq函数来处理pending的softirq的时候，当前的task是不能被抢占的，因为一旦被抢占，下一次该task被调度运行的时候很可能在其他的CPU上去了(还记得吗?softirq的pending 寄存器是per cpu的)。因此，我们不能一次性的全部减掉，那样的话有可能preempt_count等于0，那样就允许抢占了。因此，这里减去了(SOFTIRQ_DISABLE_OFFSET－1)，既保证了softirq count的bit field9~15被减去了1，又保持了preempt disable的状态。

(3)如果当前不是interrupt context的话，并且有pending的softirq，那么调用do_softirq函数来处理软中断。

(4)该来的总会来，在step 2中我们少减了1，这里补上，其实也就是preempt count-1。

(5)在softirq handler中很可能wakeup了高优先级的任务，这里最好要检查一下，看看是否需要进行调度，确保高优先级的任务得以调度执行。

5、如何处理一个被触发的soft irq

我们说softirq是一种defering task的机制，也就是说top half没有做的事情，需要延迟到bottom half中来执行。那么具体延迟到什么时候呢?这是本节需要讲述的内容，也就是说soft irq是如何调度执行的。

在上一节已经描述一个softirq被调度执行的场景，本节主要关注在中断返回现场时候调度softirq的场景。我们来看中断退出的代码，具体如下：

void irq_exit(void)

{

……

if (!in_interrupt() && local_softirq_pending())

invoke_softirq();

……

}

代码中“!in_interrupt()”这个条件可以确保下面的场景不会触发sotfirq的调度：

(1)中断handler是嵌套的。也就是说本次irq_exit是退出到上一个中断handler。当然，在新的内核中，这种情况一般不会发生，因为中断handler都是关中断执行的。

(2)本次中断是中断了softirq handler的执行。也就是说本次irq_exit是不是退出到进程上下文，而是退出到上一个softirq context。这一点也保证了在一个CPU上的softirq是串行执行的(注意：多个CPU上还是有可能并发的)

我们继续看invoke_softirq的代码：

static inline void invoke_softirq(void)

{

if (!force_irqthreads) {

#ifdef CONFIG_HAVE_IRQ_EXIT_ON_IRQ_STACK

__do_softirq();

#else

do_softirq_own_stack();

#endif

} else {

wakeup_softirqd();

}

}

force_irqthreads是和强制线程化相关的，主要用于interrupt handler的调试(一般而言，在线程环境下比在中断上下文中更容易收集调试数据)。如果系统选择了对所有的interrupt handler进行线程化处理，那么softirq也没有理由在中断上下文中处理(中断handler都在线程中执行了，softirq怎么可能在中断上下文中执行)。本身invoke_softirq这个函数是在中断上下文中被调用的，如果强制线程化，那么系统中所有的软中断都在sofirq的daemon进程中被调度执行。

如果没有强制线程化，softirq的处理也分成两种情况，主要是和softirq执行的时候使用的stack相关。如果arch支持单独的IRQ STACK，这时候，由于要退出中断，因此irq stack已经接近全空了(不考虑中断栈嵌套的情况，因此新内核下，中断不会嵌套)，因此直接调用__do_softirq()处理软中断就OK了，否则就调用do_softirq_own_stack函数在softirq自己的stack上执行。当然对ARM而言，softirq的处理就是在当前的内核栈上执行的，因此do_softirq_own_stack的调用就是调用__do_softirq()，代码如下(删除了部分无关代码)：

asmlinkage void __do_softirq(void)

{

……

pending = local_softirq_pending();－－－－－－－－－－－－－－－获取softirq pending的状态

__local_bh_disable_ip(_RET_IP_, SOFTIRQ_OFFSET);－－－标识下面的代码是正在处理softirq

cpu = smp_processor_id();

restart:

set_softirq_pending(0); －－－－－－－－－清除pending标志

local_irq_enable(); －－－－－－打开中断，softirq handler是开中断执行的

h = softirq_vec; －－－－－－－获取软中断描述符指针

while ((softirq_bit = ffs(pending))) {－－－－－－－寻找pending中第一个被设定为1的bit

unsigned int vec_nr;

int prev_count;

h += softirq_bit - 1; －－－－－－指向pending的那个软中断描述符

vec_nr = h - softirq_vec;－－－－获取soft irq number

h->action(h);－－－－－－－－－指向softirq handler

h++;

pending >>= softirq_bit;

}

local_irq_disable(); －－－－－－－关闭本地中断

pending = local_softirq_pending();－－－－－－－－－－(注1)

if (pending) {

if (time_before(jiffies, end) && !need_resched() &&

--max_restart)

goto restart;

wakeup_softirqd();

}

__local_bh_enable(SOFTIRQ_OFFSET);－－－－－－－－－－标识softirq处理完毕

}

(注1)再次检查softirq pending，有可能上面的softirq handler在执行过程中，发生了中断，又raise了softirq。如果的确如此，那么我们需要跳转到restart那里重新处理soft irq。当然，也不能总是在这里不断的loop，因此linux kernel设定了下面的条件：

(1)softirq的处理时间没有超过2个ms

(2)上次的softirq中没有设定TIF_NEED_RESCHED，也就是说没有有高优先级任务需要调度

(3)loop的次数小于 10次

因此，只有同时满足上面三个条件，程序才会跳转到restart那里重新处理soft irq。否则wakeup_softirqd就OK了。这样的设计也是一个平衡的方案。一方面照顾了调度延迟：本来，发生一个中断，系统期望在限定的时间内调度某个进程来处理这个中断，如果softirq handler不断触发，其实linux kernel是无法保证调度延迟时间的。另外一方面，也照顾了硬件的thoughput：已经预留了一定的时间来处理softirq。




## (九)：tasklet

一、前言

对于中断处理而言，linux将其分成了两个部分，一个叫做中断handler(top half)，属于不那么紧急需要处理的事情被推迟执行，我们称之deferable task，或者叫做bottom half，。具体如何推迟执行分成下面几种情况：

1、推迟到top half执行完毕

2、推迟到某个指定的时间片(例如40ms)之后执行

3、推迟到某个内核线程被调度的时候执行

对于第一种情况，内核中的机制包括softirq机制和tasklet机制。第二种情况是属于softirq机制的一种应用场景(timer类型的softirq)，在本站的时间子系统的系列文档中会描述。第三种情况主要包括threaded irq handler以及通用的workqueue机制，当然也包括自己创建该驱动专属kernel thread(不推荐使用)。本文主要描述tasklet这种机制，第二章描述一些背景知识和和tasklet的思考，第三章结合代码描述tasklet的原理。

注：本文中的linux kernel的版本是4.0

二、为什么需要tasklet?

1、基本的思考

我们的驱动程序或者内核模块真的需要tasklet吗?每个人都有自己的看法。我们先抛开linux kernel中的机制，首先进行一番逻辑思考。

将中断处理分成top half(cpu和外设之间的交互，获取状态，ack状态，收发数据等)和bottom half(后段的数据处理)已经深入人心，对于任何的OS都一样，将不那么紧急的事情推迟到bottom half中执行是OK的，具体如何推迟执行分成两种类型：有具体时间要求的(对应linux kernel中的低精度timer和高精度timer)和没有具体时间要求的。对于没有具体时间要求的又可以分成两种：

(1)越快越好型，这种实际上是有性能要求的，除了中断top half可以抢占其执行，其他的进程上下文(无论该进程的优先级多么的高)是不会影响其执行的，一言以蔽之，在不影响中断延迟的情况下，OS会尽快处理。

(2)随遇而安型。这种属于那种没有性能需求的，其调度执行依赖系统的调度器。

本质上讲，越快越好型的bottom half不应该太多，而且tasklet的callback函数不能执行时间过长，否则会产生进程调度延迟过大的现象，甚至是非常长而且不确定的延迟，对real time的系统会产生很坏的影响。

2、对linux中的bottom half机制的思考

在linux kernel中，“越快越好型”有两种，softirq和tasklet，“随遇而安型”也有两种，workqueue和threaded irq handler。“越快越好型”能否只留下一个softirq呢?对于崇尚简单就是美的程序员当然希望如此。为了回答这个问题，我们先看看tasklet对于softirq而言有哪些好处：

(1)tasklet可以动态分配，也可以静态分配，数量不限。

(2)同一种tasklet在多个cpu上也不会并行执行，这使得程序员在撰写tasklet function的时候比较方便，减少了对并发的考虑(当然损失了性能)。

对于第一种好处，其实也就是为乱用tasklet打开了方便之门，很多撰写驱动的软件工程师不会仔细考量其driver是否有性能需求就直接使用了tasklet机制。对于第二种好处，本身考虑并发就是软件工程师的职责。因此，看起来tasklet并没有引入特别的好处，而且和softirq一样，都不能sleep，限制了handler撰写的方便性，看起来其实并没有存在的必要。在4.0 kernel的代码中，grep一下tasklet的使用，实际上是一个很长的列表，只要对这些使用进行简单的归类就可以删除对tasklet的使用。对于那些有性能需求的，可以考虑并入softirq，其他的可以考虑使用workqueue来取代。Steven Rostedt试图进行这方面的尝试(http://lwn.net/Articles/239484/)，不过这个patch始终未能进入main line。

三、tasklet的基本原理

1、如何抽象一个tasklet

内核中用下面的数据结构来表示tasklet：

struct tasklet_struct

{

struct tasklet_struct *next;

unsigned long state;

atomic_t count;

void (*func)(unsigned long);

unsigned long data;

};

每个cpu都会维护一个链表，将本cpu需要处理的tasklet管理起来，next这个成员指向了该链表中的下一个tasklet。func和data成员描述了该tasklet的callback函数，func是调用函数，data是传递给func的参数。state成员表示该tasklet的状态，TASKLET_STATE_SCHED表示该tasklet以及被调度到某个CPU上执行，TASKLET_STATE_RUN表示该tasklet正在某个cpu上执行。count成员是和enable或者disable该tasklet的状态相关，如果count等于0那么该tasklet是处于enable的，如果大于0，表示该tasklet是disable的。在softirq文档中，我们知道local_bh_disable/enable函数就是用来disable/enable bottom half的，这里就包括softirq和tasklet。但是，有的时候内核同步的场景不需disable所有的softirq和tasklet，而仅仅是disable该tasklet，这时候，tasklet_disable和tasklet_enable就派上用场了。

static inline void tasklet_disable(struct tasklet_struct *t)

{

tasklet_disable_nosync(t);－－－－－－－给tasklet的count加一

tasklet_unlock_wait(t);－－－－－如果该tasklet处于running状态，那么需要等到该tasklet执行完毕

smp_mb();

}

static inline void tasklet_enable(struct tasklet_struct *t)

{

smp_mb__before_atomic();

atomic_dec(&t->count);－－－－－－－给tasklet的count减一

}

tasklet_disable和tasklet_enable支持嵌套，但是需要成对使用。

2、系统如何管理tasklet?

系统中的每个cpu都会维护一个tasklet的链表，定义如下：

static DEFINE_PER_CPU(struct tasklet_head, tasklet_vec);

static DEFINE_PER_CPU(struct tasklet_head, tasklet_hi_vec);

linux kernel中，和tasklet相关的softirq有两项，HI_SOFTIRQ用于高优先级的tasklet，TASKLET_SOFTIRQ用于普通的tasklet。对于softirq而言，优先级就是出现在softirq pending register(__softirq_pending)中的先后顺序，位于bit 0拥有最高的优先级，也就是说，如果有多个不同类型的softirq同时触发，那么执行的先后顺序依赖在softirq pending register的位置，kernel总是从右向左依次判断是否置位，如果置位则执行。HI_SOFTIRQ占据了bit 0，其优先级甚至高过timer，需要慎用(实际上，我grep了内核代码，似乎没有发现对HI_SOFTIRQ的使用)。当然HI_SOFTIRQ和TASKLET_SOFTIRQ的机理是一样的，因此本文只讨论TASKLET_SOFTIRQ，大家可以举一反三。

3、如何定义一个tasklet?

你可以用下面的宏定义来静态定义tasklet：

#define DECLARE_TASKLET(name, func, data) \

struct tasklet_struct name = { NULL, 0, ATOMIC_INIT(0), func, data }

#define DECLARE_TASKLET_DISABLED(name, func, data) \

struct tasklet_struct name = { NULL, 0, ATOMIC_INIT(1), func, data }

这两个宏都可以静态定义一个struct tasklet_struct的变量，只不过初始化后的tasklet一个是处于eable状态，一个处于disable状态的。当然，也可以动态分配tasklet，然后调用tasklet_init来初始化该tasklet。

4、如何调度一个tasklet

为了调度一个tasklet执行，我们可以使用tasklet_schedule这个接口：

static inline void tasklet_schedule(struct tasklet_struct *t)

{

if (!test_and_set_bit(TASKLET_STATE_SCHED, &t->state))

__tasklet_schedule(t);

}

程序在多个上下文中可以多次调度同一个tasklet执行(也可能来自多个cpu core)，不过实际上该tasklet只会一次挂入首次调度到的那个cpu的tasklet链表，也就是说，即便是多次调用tasklet_schedule，实际上tasklet只会挂入一个指定CPU的tasklet队列中(而且只会挂入一次)，也就是说只会调度一次执行。这是通过TASKLET_STATE_SCHED这个flag来完成的，我们可以用下面的图片来描述：

![](attachment\9.1.gif)

我们假设HW block A的驱动使用的tasklet机制并且在中断handler(top half)中将静态定义的tasklet(这个tasklet是各个cpu共享的，不是per cpu的)调度执行(也就是调用tasklet_schedule函数)。当HW block A检测到硬件的动作(例如接收FIFO中数据达到半满)就会触发IRQ line上的电平或者边缘信号，GIC检测到该信号会将该中断分发给某个CPU执行其top half handler，我们假设这次是cpu0，因此该driver的tasklet被挂入CPU0对应的tasklet链表(tasklet_vec)并将state的状态设定为TASKLET_STATE_SCHED。HW block A的驱动中的tasklet虽已调度，但是没有执行，如果这时候，硬件又一次触发中断并在cpu1上执行，虽然tasklet_schedule函数被再次调用，但是由于TASKLET_STATE_SCHED已经设定，因此不会将HW block A的驱动中的这个tasklet挂入cpu1的tasklet链表中。

下面我们再仔细研究一下底层的__tasklet_schedule函数：

void __tasklet_schedule(struct tasklet_struct *t)

{

unsigned long flags;

local_irq_save(flags);－－－－－－－－－－－－－－－－－－－(1)

t->next = NULL;－－－－－－－－－－－－－－－－－－－－－(2)

*__this_cpu_read(tasklet_vec.tail) = t;

__this_cpu_write(tasklet_vec.tail, &(t->next));

raise_softirq_irqoff(TASKLET_SOFTIRQ);－－－－－－－－－－(3)

local_irq_restore(flags);

}

(1)下面的链表操作是per-cpu的，因此这里禁止本地中断就可以拦截所有的并发。

(2)这里的三行代码就是将一个tasklet挂入链表的尾部

(3)raise TASKLET_SOFTIRQ类型的softirq。

5、在什么时机会执行tasklet?

上面描述了tasklet的调度，当然调度tasklet不等于执行tasklet，系统会在适合的时间点执行tasklet callback function。由于tasklet是基于softirq的，因此，我们首先总结一下softirq的执行场景：

(1)在中断返回用户空间(进程上下文)的时候，如果有pending的softirq，那么将执行该softirq的处理函数。这里限定了中断返回用户空间也就是意味着限制了下面两个场景的softirq被触发执行：

(a)中断返回hard interrupt context，也就是中断嵌套的场景

(b)中断返回software interrupt context，也就是中断抢占软中断上下文的场景

(2)上面的描述缺少了一种场景：中断返回内核态的进程上下文的场景，这里我们需要详细说明。进程上下文中调用local_bh_enable的时候，如果有pending的softirq，那么将执行该softirq的处理函数。由于内核同步的要求，进程上下文中有可能会调用local_bh_enable/disable来保护临界区。在临界区代码执行过程中，中断随时会到来，抢占该进程(内核态)的执行(注意：这里只是disable了bottom half，没有禁止中断)。在这种情况下，中断返回的时候是否会执行softirq handler呢?当然不会，我们disable了bottom half的执行，也就是意味着不能执行softirq handler，但是本质上bottom half应该比进程上下文有更高的优先级，一旦条件允许，要立刻抢占进程上下文的执行，因此，当立刻离开临界区，调用local_bh_enable的时候，会检查softirq pending，如果bottom half处于enable的状态，pending的softirq handler会被执行。

(3)系统太繁忙了，不过的产生中断，raise softirq，由于bottom half的优先级高，从而导致进程无法调度执行。这种情况下，softirq会推迟到softirqd这个内核线程中去执行。

对于TASKLET_SOFTIRQ类型的softirq，其handler是tasklet_action，我们来看看各个tasklet是如何执行的：

static void tasklet_action(struct softirq_action *a)

{

struct tasklet_struct *list;

local_irq_disable();－－－－－－－－－－－－－－－－－－－－－－－－－－(1)

list = __this_cpu_read(tasklet_vec.head);

__this_cpu_write(tasklet_vec.head, NULL);

__this_cpu_write(tasklet_vec.tail, this_cpu_ptr(&tasklet_vec.head));

local_irq_enable();

while (list) {－－－－－－－－－遍历tasklet链表

struct tasklet_struct *t = list;

list = list->next;

if (tasklet_trylock(t)) {－－－－－－－－－－－－－－－－－－－－－－－(2)

if (!atomic_read(&t->count)) {－－－－－－－－－－－－－－－－－－(3)

if (!test_and_clear_bit(TASKLET_STATE_SCHED, &t->state))

BUG();

t->func(t->data);

tasklet_unlock(t);

continue;－－－－－处理下一个tasklet

}

tasklet_unlock(t);－－－－清除TASKLET_STATE_RUN标记

}

local_irq_disable();－－－－－－－－－－－－－－－－－－－－－－－(4)

t->next = NULL;

*__this_cpu_read(tasklet_vec.tail) = t;

__this_cpu_write(tasklet_vec.tail, &(t->next));

__raise_softirq_irqoff(TASKLET_SOFTIRQ); －－－－－－再次触发softirq，等待下一个执行时机

local_irq_enable();

}

}

(1)从本cpu的tasklet链表中取出全部的tasklet，保存在list这个临时变量中，同时重新初始化本cpu的tasklet链表，使该链表为空。由于bottom half是开中断执行的，因此在操作tasklet链表的时候需要使用关中断保护

(2)tasklet_trylock主要是用来设定该tasklet的state为TASKLET_STATE_RUN，同时判断该tasklet是否已经处于执行状态，这个状态很重要，它决定了后续的代码逻辑。

static inline int tasklet_trylock(struct tasklet_struct *t)

{

return !test_and_set_bit(TASKLET_STATE_RUN, &(t)->state);

}

你也许会奇怪：为何这里从tasklet的链表中摘下一个本cpu要处理的tasklet list，而这个list中的tasklet已经处于running状态了，会有这种情况吗?会的，我们再次回到上面的那个软硬件结构图。同样的，HW block A的驱动使用的tasklet机制并且在中断handler(top half)中将静态定义的tasklet 调度执行。HW block A的硬件中断首先送达cpu0处理，因此该driver的tasklet被挂入CPU0对应的tasklet链表并在适当的时间点上开始执行该tasklet。这时候，cpu0的硬件中断又来了，该driver的tasklet callback function被抢占，虽然tasklet仍然处于running状态。与此同时，HW block A硬件又一次触发中断并在cpu1上执行，这时候，该driver的tasklet处于running状态，并且TASKLET_STATE_SCHED已经被清除，因此，调用tasklet_schedule函数将会使得该driver的tasklet挂入cpu1的tasklet链表中。由于cpu0在处理其他硬件中断，因此，cpu1的tasklet后发先至，进入tasklet_action函数调用，这时候，当从cpu1的tasklet摘取所有需要处理的tasklet链表中，HW block A对应的tasklet实际上已经是在cpu0上处于执行状态了。

我们在设计tasklet的时候就规定，同一种类型的tasklet只能在一个cpu上执行，因此tasklet_trylock就是起这个作用的。

(3)检查该tasklet是否处于enable状态，如果是，说明该tasklet可以真正进入执行状态了。主要的动作就是清除TASKLET_STATE_SCHED状态，执行tasklet callback function。

(4)如果该tasklet已经在别的cpu上执行了，那么我们将其挂入该cpu的tasklet链表的尾部，这样，在下一个tasklet执行时机到来的时候，kernel会再次尝试执行该tasklet，在这个时间点，也许其他cpu上的该tasklet已经执行完毕了。通过这样代码逻辑，保证了特定的tasklet只会在一个cpu上执行，不会在多个cpu上并发。




