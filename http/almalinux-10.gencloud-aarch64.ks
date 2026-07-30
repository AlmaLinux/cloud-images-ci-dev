# AlmaLinux OS 10 kickstart file for Cloud-init included and OpenStack compatible Generic Cloud images on AArch64

url --url https://repo.almalinux.org/almalinux/10/BaseOS/aarch64/os
text
lang en_US.UTF-8
keyboard us
timezone UTC --utc
selinux --enforcing
firewall --disabled
services --enabled=sshd

bootloader --timeout=0 --location=mbr --append="console=tty0 console=ttyS0,115200n8 no_timer_check net.ifnames=0"

%pre --erroronfail
fstype=xfs
for param in $(cat /proc/cmdline); do
  case $param in
    fstype=*) fstype=${param#fstype=} ;;
  esac
done

cat > /tmp/partitions.ks <<EOF
zerombr
clearpart --all --initlabel
part /boot/efi --fstype=efi --size=200
part /boot --fstype=$fstype --size=1024
part / --fstype=$fstype --grow
EOF
%end

%include /tmp/partitions.ks

rootpw --plaintext almalinux
reboot --eject

%packages --exclude-weakdeps --inst-langs=en
dracut-config-generic
pciutils
tar
# Packages the image's Ansible provisioning previously installed with dnf:
# preinstalled here so they always come from the same repositories the
# OS is installed from (and, for 9/10 PUNGI pre-release builds, so
# released-version packages are not mixed into a pre-release system).
cloud-utils-growpart
jq
nfs-utils
qemu-guest-agent
rsync
tcpdump
tuned
-*firmware
-dracut-config-rescue
-firewalld
%end

# disable kdump service
%addon com_redhat_kdump --disable
%end

%post --erroronfail

# permit root login via SSH with password authetication
echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/01-permitrootlogin.conf

%end

%post
# Import the AlmaLinux GPG keys into the RPM database. dnf used to do this
# on the first package install during the Ansible provisioning; with the
# packages preinstalled from this kickstart no dnf transaction runs anymore,
# and images would otherwise ship without the keys imported (the first
# dnf install on a running instance would then prompt to import them).
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux*
%end
