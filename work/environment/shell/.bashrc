############################################################
# djukyo@ .bashrc 2015.09.07
############################################################


############################################################
# Section
############################################################

############################################################
# ALIAS
############################################################
alias l='ls -CF'
alias ls='/bin/busybox.exe ls' # for windows
alias l='ls'
alias ll='ls -lF' # delete 'a'
#alias ll='l -l'
alias la='l -al'
alias lh='l -lh'
#alias lll='ls -CF && du -hs *'
alias ldu='l -l && du -hs *'
alias vi='vim'
alias vb='vim ~/.bashrc'
alias sb='source ~/.bashrc'
alias cb='cat ~/.bashrc'
alias vv='vim ~/.vimrc'

alias ..='cd ../ && ls -l'
alias .2='cd ../.. && ls -l'
alias .3='cd ../../.. && ls -l'
alias .4='cd ../../../.. && ls -l'
alias .5='cd ../../../../.. && ls -l'
alias .6='cd ../../../../../.. && ls -l'
alias .7='cd ../../../../../../.. && ls -l'
alias .8='cd ../../../../../../../.. && ls -l'
alias .9='cd ../../../../../../../../.. && ls -l'

###########################################################
# Linux Program
###########################################################
alias GT='gnome-terminal '
alias GV='gvim '
alias GE='gedit '
alias du.='du --max-depth=1 -h'
alias end='echo $?'
alias h='history'
alias tt='date +%H:%M'
alias ugz='gzip -d *.gz'

alias foxit='/home/dingjian/1_Application/FoxitReader/FoxitReader &'
alias pft='phoneflashtool &'
alias see='wine ~/Data/1_Software/1_Application/ACDSee.exe'
alias fsc='wine ~/Data/1_Software/1_Application/FSC_8.0/FSCapture.exe'

###########################################################
# Windows Program
###########################################################
alias BComp='/drives/c/Program\ Files/Beyond\ Compare\ 4/BComp.exe'
alias pft='/drives/c/Program\ Files\ \(x86\)/Intel/Phone\ Flash\ Tool/phoneflashtool.exe'

###########################################################
# GREP
export GREP_OPTIONS="--exclude=.repo --exclude=.git --exclude=*.IAB --exclude=*.IAD --exclude=*.IMB --exclude=*.IMD --exclude=*.PFI --exclude=*.PO --exclude=*.PR --exclude=*.PRI --exclude=*.PS --exclude=*.WK3 --binary-files=without-match"

###########################################################
# adb
alias adbs='adb shell '
alias ad='adb devices'
alias arb='adb reboot'
alias fd='fastboot devices'
alias frb='fastboot reboot'
alias akmsg='adbs cat /proc/kmsg'
alias admesg='adbs dmesg'
alias agetprop='adbs getprop'
alias adbgetlog='agetprop > getprop.txt && admesg > dmesg.txt && adb pull -p -a /data/logs/ logs/ && adb pull -p -a /data/system/dropbox/ dropbox/ && adb pull -p -a /data/core/ core/ && du -hs'
alias adbrmlog="adbs 'rm -rf /data/logs/* /data/system/dropbox/* /data/core/*'"
alias adbll="adbs \"ls -al /data/logs/* /data/system/dropbox/* /data/core/*\""
alias ALog='mkdir logs dropbox core && adbgetlog && adbrmlog '
alias apower='adbs input keyevent 26'
alias ap='apower'
alias alock='adbs input keyevent 82'
alias al='alock'
alias ash='adb shell reboot -p'

alias aintpen='adb install ~/Astro20/tool/tools/poweronoff/eng_4.0_TPowercontrol.apk'
alias aintpus='adb install ~/Astro20/tool/tools/poweronoff/user_4.0_TPowercontrol.apk'

###########################################################
# PATH
###########################################################
export JAVA_HOME=/usr/lib/jvm/java-1.7.0-openjdk-amd64
export JRE=$JAVA_HOME
#export ANDROID_HOME

# go lang
export GOROOT=~/go
export GOPATH=$GOROOT/mygo

export PATH=~/:$GOROOT/bin:$JRE/bin:$PATH

###########################################################
# SSH
###########################################################
alias dingj='ssh dingj@10.5.133.203'
alias suwg='ssh suwg@10.5.133.204'

###########################################################
# test
export WINPATH="/drives/c/Program Files/"
