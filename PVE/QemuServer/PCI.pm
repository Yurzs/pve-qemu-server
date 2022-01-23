package PVE::QemuServer::PCI;

use warnings;
use strict;

use PVE::JSONSchema;
use PVE::SysFSTools;
use PVE::Tools;

use base 'Exporter';

our @EXPORT_OK = qw(
print_pci_addr
print_pcie_addr
print_pcie_root_port
parse_hostpci
);

our $MAX_HOSTPCI_DEVICES = 16;

my $PCIRE = qr/(?:[a-f0-9]{4}:)?[a-f0-9]{2}:[a-f0-9]{2}(?:\.[a-f0-9])?/;
my $hostpci_fmt = {
    host => {
	default_key => 1,
	type => 'string',
	pattern => qr/$PCIRE(;$PCIRE)*/,
	format_description => 'HOSTPCIID[;HOSTPCIID2...]',
	description => <<EODESCR,
Host PCI device pass through. The PCI ID of a host's PCI device or a list
of PCI virtual functions of the host. HOSTPCIID syntax is:

'bus:dev.func' (hexadecimal numbers)

You can us the 'lspci' command to list existing PCI devices.
EODESCR
    },
    rombar => {
	type => 'boolean',
	description =>  "Specify whether or not the device's ROM will be visible in the"
	    ." guest's memory map.",
	optional => 1,
	default => 1,
    },
    romfile => {
	type => 'string',
	pattern => '[^,;]+',
	format_description => 'string',
	description => "Custom pci device rom filename (must be located in /usr/share/kvm/).",
	optional => 1,
    },
    pcie => {
	type => 'boolean',
	description =>  "Choose the PCI-express bus (needs the 'q35' machine model).",
	optional => 1,
	default => 0,
    },
    'x-vga' => {
	type => 'boolean',
	description =>  "Enable vfio-vga device support.",
	optional => 1,
	default => 0,
    },
    'legacy-igd' => {
	type => 'boolean',
	description => "Pass this device in legacy IGD mode, making it the primary and exclusive"
	    ." graphics device in the VM. Requires 'pc-i440fx' machine type and VGA set to 'none'.",
	optional => 1,
	default => 0,
    },
    'mdev' => {
	type => 'string',
	format_description => 'string',
	pattern => '[^/\.:]+',
	optional => 1,
	description => <<EODESCR
The type of mediated device to use.
An instance of this type will be created on startup of the VM and
will be cleaned up when the VM stops.
EODESCR
    }
};
PVE::JSONSchema::register_format('pve-qm-hostpci', $hostpci_fmt);

our $hostpcidesc = {
	optional => 1,
	type => 'string', format => 'pve-qm-hostpci',
	description => "Map host PCI devices into guest.",
	verbose_description =>  <<EODESCR,
Map host PCI devices into guest.

NOTE: This option allows direct access to host hardware. So it is no longer
possible to migrate such machines - use with special care.

CAUTION: Experimental! User reported problems with this option.
EODESCR
};
PVE::JSONSchema::register_standard_option("pve-qm-hostpci", $hostpcidesc);

my $pci_addr_map;
sub get_pci_addr_map {
    $pci_addr_map = {
	piix3 => { bus => 0, addr => 1, conflict_ok => qw(ehci)  },
	ehci => { bus => 0, addr => 1, conflict_ok => qw(piix3) }, # instead of piix3 on arm
	vga => { bus => 0, addr => 2, conflict_ok => qw(legacy-igd) },
	'legacy-igd' => { bus => 0, addr => 2, conflict_ok => qw(vga) }, # legacy-igd requires vga=none
	balloon0 => { bus => 0, addr => 3 },
	watchdog => { bus => 0, addr => 4 },
	scsihw0 => { bus => 0, addr => 5, conflict_ok => qw(pci.3) },
	'pci.3' => { bus => 0, addr => 5, conflict_ok => qw(scsihw0) }, # also used for virtio-scsi-single bridge
	scsihw1 => { bus => 0, addr => 6 },
	ahci0 => { bus => 0, addr => 7 },
	qga0 => { bus => 0, addr => 8 },
	spice => { bus => 0, addr => 9 },
	virtio0 => { bus => 0, addr => 10 },
	virtio1 => { bus => 0, addr => 11 },
	virtio2 => { bus => 0, addr => 12 },
	virtio3 => { bus => 0, addr => 13 },
	virtio4 => { bus => 0, addr => 14 },
	virtio5 => { bus => 0, addr => 15 },
	hostpci0 => { bus => 0, addr => 16 },
	hostpci1 => { bus => 0, addr => 17 },
	net0 => { bus => 0, addr => 18 },
	net1 => { bus => 0, addr => 19 },
	net2 => { bus => 0, addr => 20 },
	net3 => { bus => 0, addr => 21 },
	net4 => { bus => 0, addr => 22 },
	net5 => { bus => 0, addr => 23 },
	vga1 => { bus => 0, addr => 24 },
	vga2 => { bus => 0, addr => 25 },
	vga3 => { bus => 0, addr => 26 },
	hostpci2 => { bus => 0, addr => 27 },
	hostpci3 => { bus => 0, addr => 28 },
	#addr29 : usb-host (pve-usb.cfg)
	'pci.1' => { bus => 0, addr => 30 },
	'pci.2' => { bus => 0, addr => 31 },
	'net6' => { bus => 1, addr => 1 },
	'net7' => { bus => 1, addr => 2 },
	'net8' => { bus => 1, addr => 3 },
	'net9' => { bus => 1, addr => 4 },
	'net10' => { bus => 1, addr => 5 },
	'net11' => { bus => 1, addr => 6 },
	'net12' => { bus => 1, addr => 7 },
	'net13' => { bus => 1, addr => 8 },
	'net14' => { bus => 1, addr => 9 },
	'net15' => { bus => 1, addr => 10 },
	'net16' => { bus => 1, addr => 11 },
	'net17' => { bus => 1, addr => 12 },
	'net18' => { bus => 1, addr => 13 },
	'net19' => { bus => 1, addr => 14 },
	'net20' => { bus => 1, addr => 15 },
	'net21' => { bus => 1, addr => 16 },
	'net22' => { bus => 1, addr => 17 },
	'net23' => { bus => 1, addr => 18 },
	'net24' => { bus => 1, addr => 19 },
	'net25' => { bus => 1, addr => 20 },
	'net26' => { bus => 1, addr => 21 },
	'net27' => { bus => 1, addr => 22 },
	'net28' => { bus => 1, addr => 23 },
	'net29' => { bus => 1, addr => 24 },
	'net30' => { bus => 1, addr => 25 },
	'net31' => { bus => 1, addr => 26 },
	'xhci' => { bus => 1, addr => 27 },
	'pci.4' => { bus => 1, addr => 28 },
	'rng0' => { bus => 1, addr => 29 },
	'pci.2-igd' => { bus => 1, addr => 30 }, # replaces pci.2 in case a legacy IGD device is passed through
	'virtio6' => { bus => 2, addr => 1 },
	'virtio7' => { bus => 2, addr => 2 },
	'virtio8' => { bus => 2, addr => 3 },
	'virtio9' => { bus => 2, addr => 4 },
	'virtio10' => { bus => 2, addr => 5 },
	'virtio11' => { bus => 2, addr => 6 },
	'virtio12' => { bus => 2, addr => 7 },
	'virtio13' => { bus => 2, addr => 8 },
	'virtio14' => { bus => 2, addr => 9 },
	'virtio15' => { bus => 2, addr => 10 },
	'ivshmem' => { bus => 2, addr => 11 },
	'audio0' => { bus => 2, addr => 12 },
	hostpci4 => { bus => 2, addr => 13 },
	hostpci5 => { bus => 2, addr => 14 },
	hostpci6 => { bus => 2, addr => 15 },
	hostpci7 => { bus => 2, addr => 16 },
	hostpci8 => { bus => 2, addr => 17 },
	hostpci9 => { bus => 2, addr => 18 },
	hostpci10 => { bus => 2, addr => 19 },
	hostpci11 => { bus => 2, addr => 20 },
	hostpci12 => { bus => 2, addr => 21 },
	hostpci13 => { bus => 2, addr => 22 },
	hostpci14 => { bus => 2, addr => 23 },
	hostpci15 => { bus => 2, addr => 24 },
	'virtioscsi0' => { bus => 3, addr => 1 },
	'virtioscsi1' => { bus => 3, addr => 2 },
	'virtioscsi2' => { bus => 3, addr => 3 },
	'virtioscsi3' => { bus => 3, addr => 4 },
	'virtioscsi4' => { bus => 3, addr => 5 },
	'virtioscsi5' => { bus => 3, addr => 6 },
	'virtioscsi6' => { bus => 3, addr => 7 },
	'virtioscsi7' => { bus => 3, addr => 8 },
	'virtioscsi8' => { bus => 3, addr => 9 },
	'virtioscsi9' => { bus => 3, addr => 10 },
	'virtioscsi10' => { bus => 3, addr => 11 },
	'virtioscsi11' => { bus => 3, addr => 12 },
	'virtioscsi12' => { bus => 3, addr => 13 },
	'virtioscsi13' => { bus => 3, addr => 14 },
	'virtioscsi14' => { bus => 3, addr => 15 },
	'virtioscsi15' => { bus => 3, addr => 16 },
	'virtioscsi16' => { bus => 3, addr => 17 },
	'virtioscsi17' => { bus => 3, addr => 18 },
	'virtioscsi18' => { bus => 3, addr => 19 },
	'virtioscsi19' => { bus => 3, addr => 20 },
	'virtioscsi20' => { bus => 3, addr => 21 },
	'virtioscsi21' => { bus => 3, addr => 22 },
	'virtioscsi22' => { bus => 3, addr => 23 },
	'virtioscsi23' => { bus => 3, addr => 24 },
	'virtioscsi24' => { bus => 3, addr => 25 },
	'virtioscsi25' => { bus => 3, addr => 26 },
	'virtioscsi26' => { bus => 3, addr => 27 },
	'virtioscsi27' => { bus => 3, addr => 28 },
	'virtioscsi28' => { bus => 3, addr => 29 },
	'virtioscsi29' => { bus => 3, addr => 30 },
	'virtioscsi30' => { bus => 3, addr => 31 },
	'scsihw2' => { bus => 4, addr => 1 },
	'scsihw3' => { bus => 4, addr => 2 },
	'scsihw4' => { bus => 4, addr => 3 },
    } if !defined($pci_addr_map);
    return $pci_addr_map;
}

my $consumer_mdev_map;
sub get_consumer_mdev_map {
	$consumer_mdev_map = {
		"0x21c4" => "0x1e3c",
		"0x21d1" => "0x1e3c",
		"0x21c2" => "0x1e3c",
		"0x2182" => "0x1e3c",
		"0x2183" => "0x1e3c",
		"0x2184" => "0x1e3c",
		"0x2187" => "0x1e3c",
		"0x2188" => "0x1e3c",
		"0x2191" => "0x1e3c",
		"0x2192" => "0x1e3c",
		"0x21ae" => "0x1e3c",
		"0x21bf" => "0x1e3c",
		"0x2189" => "0x1e3c",
		"0x1fbf" => "0x1e3c",
		"0x1fbb" => "0x1e3c",
		"0x1fd9" => "0x1e3c",
		"0x1ff9" => "0x1e3c",
		"0x1fdd" => "0x1e3c",
		"0x1f96" => "0x1e3c",
		"0x1f99" => "0x1e3c",
		"0x1fae" => "0x1e3c",
		"0x1fb8" => "0x1e3c",
		"0x1fb9" => "0x1e3c",
		"0x1f97" => "0x1e3c",
		"0x1f98" => "0x1e3c",
		"0x1f9c" => "0x1e3c",
		"0x1f9d" => "0x1e3c",
		"0x1fb0" => "0x1e3c",
		"0x1fb1" => "0x1e3c",
		"0x1fb2" => "0x1e3c",
		"0x1fba" => "0x1e3c",
		"0x1f42" => "0x1e3c",
		"0x1f47" => "0x1e3c",
		"0x1f50" => "0x1e3c",
		"0x1f51" => "0x1e3c",
		"0x1f54" => "0x1e3c",
		"0x1f55" => "0x1e3c",
		"0x1f81" => "0x1e3c",
		"0x1f82" => "0x1e3c",
		"0x1f91" => "0x1e3c",
		"0x1f92" => "0x1e3c",
		"0x1f94" => "0x1e3c",
		"0x1f95" => "0x1e3c",
		"0x1f76" => "0x1e3c",
		"0x1f07" => "0x1e3c",
		"0x1f08" => "0x1e3c",
		"0x1f09" => "0x1e3c",
		"0x1f0a" => "0x1e3c",
		"0x1f10" => "0x1e3c",
		"0x1f11" => "0x1e3c",
		"0x1f12" => "0x1e3c",
		"0x1f14" => "0x1e3c",
		"0x1f15" => "0x1e3c",
		"0x1f2e" => "0x1e3c",
		"0x1f36" => "0x1e3c",
		"0x1f0b" => "0x1e3c",
		"0x1eb5" => "0x1e3c",
		"0x1eb6" => "0x1e3c",
		"0x1eb8" => "0x1e3c",
		"0x1eb9" => "0x1e3c",
		"0x1ebe" => "0x1e3c",
		"0x1ec2" => "0x1e3c",
		"0x1ec7" => "0x1e3c",
		"0x1ed0" => "0x1e3c",
		"0x1ed1" => "0x1e3c",
		"0x1ed3" => "0x1e3c",
		"0x1f02" => "0x1e3c",
		"0x1f04" => "0x1e3c",
		"0x1f06" => "0x1e3c",
		"0x1ef5" => "0x1e3c",
		"0x1e81" => "0x1e3c",
		"0x1e82" => "0x1e3c",
		"0x1e84" => "0x1e3c",
		"0x1e87" => "0x1e3c",
		"0x1e89" => "0x1e3c",
		"0x1e90" => "0x1e3c",
		"0x1e91" => "0x1e3c",
		"0x1e93" => "0x1e3c",
		"0x1eab" => "0x1e3c",
		"0x1eae" => "0x1e3c",
		"0x1eb0" => "0x1e3c",
		"0x1eb1" => "0x1e3c",
		"0x1eb4" => "0x1e3c",
		"0x1e04" => "0x1e3c",
		"0x1e07" => "0x1e3c",
		"0x1e2d" => "0x1e3c",
		"0x1e2e" => "0x1e3c",
		"0x1e30" => "0x1e3c",
		"0x1e36" => "0x1e3c",
		"0x1e37" => "0x1e3c",
		"0x1e38" => "0x1e3c",
		"0x1e3c" => "0x1e3c",
		"0x1e3d" => "0x1e3c",
		"0x1e3e" => "0x1e3c",
		"0x1e78" => "0x1e3c",
		"0x1e09" => "0x1e3c",
		"0x1dba" => "0x1db6",
		"0x1e02" => "0x1e3c",
		"0x1cfa" => "0x1b38",
		"0x1cfb" => "0x1b38",
		"0x1d01" => "0x1b38",
		"0x1d10" => "0x1b38",
		"0x1d11" => "0x1b38",
		"0x1d12" => "0x1b38",
		"0x1d13" => "0x1b38",
		"0x1d16" => "0x1b38",
		"0x1d33" => "0x1b38",
		"0x1d34" => "0x1b38",
		"0x1d52" => "0x1b38",
		"0x1d56" => "0x1b38",
		"0x1d81" => "0x1db6",
		"0x1cb6" => "0x1b38",
		"0x1cba" => "0x1b38",
		"0x1cbb" => "0x1b38",
		"0x1cbc" => "0x1b38",
		"0x1cbd" => "0x1b38",
		"0x1ccc" => "0x1b38",
		"0x1ccd" => "0x1b38",
		"0x1ca8" => "0x1b38",
		"0x1caa" => "0x1b38",
		"0x1cb1" => "0x1b38",
		"0x1cb2" => "0x1b38",
		"0x1cb3" => "0x1b38",
		"0x1c70" => "0x1b38",
		"0x1c81" => "0x1b38",
		"0x1c82" => "0x1b38",
		"0x1c83" => "0x1b38",
		"0x1c8c" => "0x1b38",
		"0x1c8d" => "0x1b38",
		"0x1c8e" => "0x1b38",
		"0x1c8f" => "0x1b38",
		"0x1c90" => "0x1b38",
		"0x1c91" => "0x1b38",
		"0x1c92" => "0x1b38",
		"0x1c94" => "0x1b38",
		"0x1c96" => "0x1b38",
		"0x1ca7" => "0x1b38",
		"0x1c36" => "0x1b38",
		"0x1c07" => "0x1b38",
		"0x1c09" => "0x1b38",
		"0x1c20" => "0x1b38",
		"0x1c21" => "0x1b38",
		"0x1c22" => "0x1b38",
		"0x1c23" => "0x1b38",
		"0x1c2d" => "0x1b38",
		"0x1c30" => "0x1b38",
		"0x1c31" => "0x1b38",
		"0x1c35" => "0x1b38",
		"0x1c60" => "0x1b38",
		"0x1c61" => "0x1b38",
		"0x1c62" => "0x1b38",
		"0x1bb8" => "0x1b38",
		"0x1bb9" => "0x1b38",
		"0x1bbb" => "0x1b38",
		"0x1bc7" => "0x1b38",
		"0x1be0" => "0x1b38",
		"0x1be1" => "0x1b38",
		"0x1c00" => "0x1b38",
		"0x1c01" => "0x1b38",
		"0x1c02" => "0x1b38",
		"0x1c03" => "0x1b38",
		"0x1c04" => "0x1b38",
		"0x1c06" => "0x1b38",
		"0x1b87" => "0x1b38",
		"0x1ba0" => "0x1b38",
		"0x1ba1" => "0x1b38",
		"0x1ba2" => "0x1b38",
		"0x1ba9" => "0x1b38",
		"0x1baa" => "0x1b38",
		"0x1bad" => "0x1b38",
		"0x1bb0" => "0x1b38",
		"0x1bb1" => "0x1b38",
		"0x1bb3" => "0x1b38",
		"0x1bb4" => "0x1b38",
		"0x1bb5" => "0x1b38",
		"0x1bb6" => "0x1b38",
		"0x1bb7" => "0x1b38",
		"0x1b06" => "0x1b38",
		"0x1b07" => "0x1b38",
		"0x1b30" => "0x1b38",
		"0x1b38" => "0x1b38",
		"0x1b70" => "0x1b38",
		"0x1b78" => "0x1b38",
		"0x1b80" => "0x1bb0",
		"0x1b81" => "0x1b38",
		"0x1b82" => "0x1b38",
		"0x1b83" => "0x1b38",
		"0x1b84" => "0x1b38",
		"0x1b39" => "0x1b38",
		"0x1b00" => "0x1b38",
		"0x1b01" => "0x1b38",
		"0x1b02" => "0x1b38",
		"0x1b04" => "0x1b38",
		# "0x179c" => "Tesla M10",
		# "0x17c2" => "Tesla M60",
		# "0x17c8" => "Tesla M60",
		# "0x17f0" => "Tesla M60",
		# "0x17f1" => "Tesla M60",
		# "0x17fd" => "Tesla M60",
		# "0x1617" => "Tesla M60",
		# "0x1618" => "Tesla M60",
		# "0x1619" => "Tesla M60",
		# "0x161a" => "Tesla M60",
		# "0x1667" => "Tesla M60",
		"0x1725" => "0x1b38",
		"0x172e" => "0x1b38",
		"0x172f" => "0x1b38",
		# "0x174d" => "Tesla M10",
		# "0x174e" => "Tesla M10",
		# "0x1789" => "Tesla M10",
		# "0x1402" => "Tesla M60",
		# "0x1406" => "Tesla M60",
		# "0x1407" => "Tesla M60",
		# "0x1427" => "Tesla M60",
		# "0x1430" => "Tesla M60",
		# "0x1431" => "Tesla M60",
		# "0x1436" => "Tesla M60",
		"0x15f0" => "0x1b38",
		"0x15f1" => "0x1b38",
		# "0x1404" => "Tesla M60",
		# "0x13d8" => "Tesla M60",
		# "0x13d9" => "Tesla M60",
		# "0x13da" => "Tesla M60",
		# "0x13e7" => "Tesla M60",
		# "0x13f0" => "Tesla M60",
		# "0x13f1" => "Tesla M60",
		# "0x13f2" => "Tesla M60",
		# "0x13f3" => "Tesla M60",
		# "0x13f8" => "Tesla M60",
		# "0x13f9" => "Tesla M60",
		# "0x13fa" => "Tesla M60",
		# "0x13fb" => "Tesla M60",
		# "0x1401" => "Tesla M60",
		# "0x13b3" => "Tesla M10",
		# "0x13b4" => "Tesla M10",
		# "0x13b6" => "Tesla M10",
		# "0x13b9" => "Tesla M10",
		# "0x13ba" => "Tesla M10",
		# "0x13bb" => "Tesla M10",
		# "0x13bc" => "Tesla M10",
		# "0x13bd" => "Tesla M10",
		# "0x13c0" => "Tesla M60",
		# "0x13c1" => "Tesla M60",
		# "0x13c2" => "Tesla M60",
		# "0x13c3" => "Tesla M60",
		# "0x13d7" => "Tesla M60",
		# "0x1389" => "Tesla M10",
		# "0x1390" => "Tesla M10",
		# "0x1391" => "Tesla M10",
		# "0x1392" => "Tesla M10",
		# "0x1393" => "Tesla M10",
		# "0x1398" => "Tesla M10",
		# "0x1399" => "Tesla M10",
		# "0x139a" => "Tesla M10",
		# "0x139b" => "Tesla M10",
		# "0x139c" => "Tesla M10",
		# "0x139d" => "Tesla M10",
		# "0x13b0" => "Tesla M10",
		# "0x13b1" => "Tesla M10",
		# "0x13b2" => "Tesla M10",
		# "0x1347" => "Tesla M10",
		# "0x1348" => "Tesla M10",
		# "0x1349" => "Tesla M10",
		# "0x134b" => "Tesla M10",
		# "0x134d" => "Tesla M10",
		# "0x134e" => "Tesla M10",
		# "0x134f" => "Tesla M10",
		# "0x137a" => "Tesla M10",
		# "0x137b" => "Tesla M10",
		# "0x137d" => "Tesla M10",
		# "0x1380" => "Tesla M10",
		# "0x1381" => "Tesla M10",
		# "0x1382" => "Tesla M10",
		# "0x1340" => "Tesla M10",
		# "0x1341" => "Tesla M10",
		# "0x1344" => "Tesla M10",
		# "0x1346" => "Tesla M10",
	} if !defined($consumer_mdev_map);
	return $consumer_mdev_map;
}

my sub generate_mdev_uuid {
    my ($vmid, $index) = @_;
    return sprintf("%08d-0000-0000-0000-%012d", $index, $vmid);
}

my $get_addr_mapping_from_id = sub {
    my ($map, $id) = @_;

    my $d = $map->{$id};
    return if !defined($d) || !defined($d->{bus}) || !defined($d->{addr});

    return { bus => $d->{bus}, addr => sprintf("0x%x", $d->{addr}) };
};

sub print_pci_addr {
    my ($id, $bridges, $arch, $machine) = @_;

    my $res = '';

    # using same bus slots on all HW, so we need to check special cases here:
    my $busname = 'pci';
    if ($arch eq 'aarch64' && $machine =~ /^virt/) {
	die "aarch64/virt cannot use IDE devices\n" if $id =~ /^ide/;
	$busname = 'pcie';
    }

    my $map = get_pci_addr_map();
    if (my $d = $get_addr_mapping_from_id->($map, $id)) {
	$res = ",bus=$busname.$d->{bus},addr=$d->{addr}";
	$bridges->{$d->{bus}} = 1 if $bridges;
    }

    return $res;
}

my $pcie_addr_map;
sub get_pcie_addr_map {
    $pcie_addr_map = {
	vga => { bus => 'pcie.0', addr => 1 },
	hostpci0 => { bus => "ich9-pcie-port-1", addr => 0 },
	hostpci1 => { bus => "ich9-pcie-port-2", addr => 0 },
	hostpci2 => { bus => "ich9-pcie-port-3", addr => 0 },
	hostpci3 => { bus => "ich9-pcie-port-4", addr => 0 },
	hostpci4 => { bus => "ich9-pcie-port-5", addr => 0 },
	hostpci5 => { bus => "ich9-pcie-port-6", addr => 0 },
	hostpci6 => { bus => "ich9-pcie-port-7", addr => 0 },
	hostpci7 => { bus => "ich9-pcie-port-8", addr => 0 },
	hostpci8 => { bus => "ich9-pcie-port-9", addr => 0 },
	hostpci9 => { bus => "ich9-pcie-port-10", addr => 0 },
	hostpci10 => { bus => "ich9-pcie-port-11", addr => 0 },
	hostpci11 => { bus => "ich9-pcie-port-12", addr => 0 },
	hostpci12 => { bus => "ich9-pcie-port-13", addr => 0 },
	hostpci13 => { bus => "ich9-pcie-port-14", addr => 0 },
	hostpci14 => { bus => "ich9-pcie-port-15", addr => 0 },
	hostpci15 => { bus => "ich9-pcie-port-16", addr => 0 },
	# win7 is picky about pcie assignments
	hostpci0bus0 => { bus => "pcie.0", addr => 16 },
	hostpci1bus0 => { bus => "pcie.0", addr => 17 },
	hostpci2bus0 => { bus => "pcie.0", addr => 18 },
	hostpci3bus0 => { bus => "pcie.0", addr => 19 },
	ivshmem => { bus => 'pcie.0', addr => 20 },
	hostpci4bus0 => { bus => "pcie.0", addr => 9 },
	hostpci5bus0 => { bus => "pcie.0", addr => 10 },
	hostpci6bus0 => { bus => "pcie.0", addr => 11 },
	hostpci7bus0 => { bus => "pcie.0", addr => 12 },
	hostpci8bus0 => { bus => "pcie.0", addr => 13 },
	hostpci9bus0 => { bus => "pcie.0", addr => 14 },
	hostpci10bus0 => { bus => "pcie.0", addr => 15 },
	hostpci11bus0 => { bus => "pcie.0", addr => 21 },
	hostpci12bus0 => { bus => "pcie.0", addr => 22 },
	hostpci13bus0 => { bus => "pcie.0", addr => 23 },
	hostpci14bus0 => { bus => "pcie.0", addr => 24 },
	hostpci15bus0 => { bus => "pcie.0", addr => 25 },
    } if !defined($pcie_addr_map);

    return $pcie_addr_map;
}

sub print_pcie_addr {
    my ($id) = @_;

    my $res = '';

    my $map = get_pcie_addr_map($id);
    if (my $d = $get_addr_mapping_from_id->($map, $id)) {
	$res = ",bus=$d->{bus},addr=$d->{addr}";
    }

    return $res;
}

# Generates the device strings for additional pcie root ports. The first 4 pcie
# root ports are defined in the pve-q35*.cfg files.
sub print_pcie_root_port {
    my ($i) = @_;
    my $res = '';

    my $root_port_addresses = {
	 4 => "10.0",
	 5 => "10.1",
	 6 => "10.2",
	 7 => "10.3",
	 8 => "10.4",
	 9 => "10.5",
	10 => "10.6",
	11 => "10.7",
	12 => "11.0",
	13 => "11.1",
	14 => "11.2",
	15 => "11.3",
    };

    if (defined($root_port_addresses->{$i})) {
	my $id = $i + 1;
	$res = "pcie-root-port,id=ich9-pcie-port-${id}";
	$res .= ",addr=$root_port_addresses->{$i}";
	$res .= ",x-speed=16,x-width=32,multifunction=on,bus=pcie.0";
	$res .= ",port=${id},chassis=${id}";
    }

    return $res;
}

sub parse_hostpci {
    my ($value) = @_;

    return if !$value;

    my $res = PVE::JSONSchema::parse_property_string($hostpci_fmt, $value);

    my @idlist = split(/;/, $res->{host});
    delete $res->{host};
    foreach my $id (@idlist) {
	my $devs = PVE::SysFSTools::lspci($id);
	die "no PCI device found for '$id'\n" if !scalar(@$devs);
	push @{$res->{pciid}}, @$devs;
    }
    return $res;
}

sub print_hostpci_devices {
    my ($vmid, $conf, $devices, $vga, $winversion, $q35, $bridges, $arch, $machine_type, $bootorder) = @_;

    my $kvm_off = 0;
    my $gpu_passthrough = 0;
    my $legacy_igd = 0;

    my $pciaddr;
    for (my $i = 0; $i < $MAX_HOSTPCI_DEVICES; $i++)  {
	my $id = "hostpci$i";
	my $d = parse_hostpci($conf->{$id});
	next if !$d;

	if (my $pcie = $d->{pcie}) {
	    die "q35 machine model is not enabled" if !$q35;
	    # win7 wants to have the pcie devices directly on the pcie bus
	    # instead of in the root port
	    if ($winversion == 7) {
		$pciaddr = print_pcie_addr("${id}bus0");
	    } else {
		# add more root ports if needed, 4 are present by default
		# by pve-q35 cfgs, rest added here on demand.
		if ($i > 3) {
		    push @$devices, '-device', print_pcie_root_port($i);
		}
		$pciaddr = print_pcie_addr($id);
	    }
	} else {
	    my $pci_name = $d->{'legacy-igd'} ? 'legacy-igd' : $id;
	    $pciaddr = print_pci_addr($pci_name, $bridges, $arch, $machine_type);
	}

	my $pcidevices = $d->{pciid};
	my $multifunction = @$pcidevices > 1;

	if ($d->{'legacy-igd'}) {
	    die "only one device can be assigned in legacy-igd mode\n"
		if $legacy_igd;
	    $legacy_igd = 1;

	    die "legacy IGD assignment requires VGA mode to be 'none'\n"
		if !defined($conf->{'vga'}) || $conf->{'vga'} ne 'none';
	    die "legacy IGD assignment requires rombar to be enabled\n"
		if defined($d->{rombar}) && !$d->{rombar};
	    die "legacy IGD assignment is not compatible with x-vga\n"
		if $d->{'x-vga'};
	    die "legacy IGD assignment is not compatible with mdev\n"
		if $d->{mdev};
	    die "legacy IGD assignment is not compatible with q35\n"
		if $q35;
	    die "legacy IGD assignment is not compatible with multifunction devices\n"
		if $multifunction;
	    die "legacy IGD assignment only works for devices on host bus 00:02.0\n"
		if $pcidevices->[0]->{id} !~ m/02\.0$/;
	}

	my $xvga = '';
	if ($d->{'x-vga'}) {
	    $xvga = ',x-vga=on' if !($conf->{bios} && $conf->{bios} eq 'ovmf');
	    $kvm_off = 1;
	    $vga->{type} = 'none' if !defined($conf->{vga});
	    $gpu_passthrough = 1;
	}

	my $mdev;
	if ($d->{mdev} && scalar(@$pcidevices) == 1) {
	    my $pci_id = $pcidevices->[0]->{id};
	    my $uuid = generate_mdev_uuid($vmid, $i);
		my $gpu_info = PVE::SysFSTools::lspci($pci_id, 1)->[0];
		if ($gpu_info->{device_name} =~ m/GTX/ || $gpu_info->{device_name} =~ /RTX/) {

			$mdev = {
				"id"                  => "$id.0",
				"bus"                 => get_pcie_addr_map()->{$id}->{bus},
				"pciaddr"             => "$pciaddr.0",
				"mf_addr"             => "0x0.0",
				"display"             => "off",
				"x_pci_vendor_id"     => $gpu_info->{"vendor"},
				"x_pci_device_id"     => get_consumer_mdev_map()->{$gpu_info->{"device"}},
				"x_pci_sub_vendor_id" => $gpu_info->{"subsystem_vendor"},
				"x_pci_sub_device_id" => $gpu_info->{"subsystem_device"},
			};

			$mdev->{"vendor_info"} = "x-pci-vendor-id=$mdev->{x_pci_vendor_id}";
			$mdev->{"vendor_info"} .= ",x-pci-device-id=$mdev->{x_pci_device_id}";
			$mdev->{"vendor_info"} .= ",x-pci-sub-vendor-id=$mdev->{x_pci_vendor_id}";
			$mdev->{"vendor_info"} .= ",x-pci-sub-device-id=0x11A0";

			$mdev->{"full_string"} = "sysfsdev=/sys/bus/mdev/devices/$uuid";
			$mdev->{"full_string"} .= ",id=$mdev->{id},bus=$mdev->{bus},addr=$mdev->{mf_addr}";
			$mdev->{"full_string"} .= ",display=$mdev->{display}";
			$mdev->{"full_string"} .= ",$mdev->{vendor_info}";

		} else {
			$mdev->{"full_string"} = "sysfsdev=/sys/bus/pci/devices/$pci_id/$uuid";
			$mdev->{"full_string"} .= ",id=${id}${pciaddr}";
		}

	} elsif ($d->{mdev}) {
	    warn "ignoring mediated device '$id' with multifunction device\n";
	}

	my $j = 0;
	foreach my $pcidevice (@$pcidevices) {
	    my $devicestr = "vfio-pci";

	    if ($mdev) {
			$devicestr .= ",$mdev->{full_string}";
	    } else {
			$devicestr .= ",host=$pcidevice->{id}";

			my $mf_addr = $multifunction ? ".$j" : '';
			$devicestr .= ",id=${id}${mf_addr}${pciaddr}${mf_addr}";

			if ($j == 0) {
				$devicestr .= ',rombar=0' if defined($d->{rombar}) && !$d->{rombar};
				$devicestr .= "$xvga";
				$devicestr .= ",multifunction=on" if $multifunction;
				$devicestr .= ",romfile=/usr/share/kvm/$d->{romfile}" if $d->{romfile};
				$devicestr .= ",bootindex=$bootorder->{$id}" if $bootorder->{$id};
			}
		}

	    push @$devices, '-device', $devicestr;
	    $j++;
	}
    }

    return ($kvm_off, $gpu_passthrough, $legacy_igd);
}

sub prepare_pci_device {
    my ($vmid, $pciid, $index, $mdev) = @_;

    my $info = PVE::SysFSTools::pci_device_info("$pciid");
    die "cannot prepare PCI pass-through, IOMMU not present\n" if !PVE::SysFSTools::check_iommu_support();
    die "no pci device info for device '$pciid'\n" if !$info;

    if ($mdev) {
		my $uuid = generate_mdev_uuid($vmid, $index);
		PVE::SysFSTools::pci_create_mdev_device($pciid, $uuid, $mdev);
		return $uuid;
    } else {
	die "can't unbind/bind PCI group to VFIO '$pciid'\n"
	    if !PVE::SysFSTools::pci_dev_group_bind_to_vfio($pciid);
	die "can't reset PCI device '$pciid'\n"
	    if $info->{has_fl_reset} && !PVE::SysFSTools::pci_dev_reset($info);
    }
}

my $RUNDIR = '/run/qemu-server';
my $PCIID_RESERVATION_FILE = "${RUNDIR}/pci-id-reservations";
my $PCIID_RESERVATION_LOCK = "${PCIID_RESERVATION_FILE}.lock";

my $parse_pci_reservation_unlocked = sub {
    my $pciids = {};
    if (my $fh = IO::File->new($PCIID_RESERVATION_FILE, "r")) {
	while (my $line = <$fh>) {
	    if ($line =~ m/^($PCIRE)\s(\d+)\s(time|pid)\:(\d+)$/) {
		$pciids->{$1} = {
		    vmid => $2,
		    "$3" => $4,
		};
	    }
	}
    }
    return $pciids;
};

my $write_pci_reservation_unlocked = sub {
    my ($reservations) = @_;

    my $data = "";
    for my $pci_id (sort keys $reservations->%*) {
	my ($vmid, $pid, $time) = $reservations->{$pci_id}->@{'vmid', 'pid', 'time'};
	if (defined($pid)) {
	    $data .= "$pci_id $vmid pid:$pid\n";
	} else {
	    $data .= "$pci_id $vmid time:$time\n";
	}
    }
    PVE::Tools::file_set_contents($PCIID_RESERVATION_FILE, $data);
};

sub remove_pci_reservation {
    my ($dropped_ids) = @_;

    $dropped_ids = [ $dropped_ids ] if !ref($dropped_ids);
    return if !scalar(@$dropped_ids); # do nothing for empty list

    PVE::Tools::lock_file($PCIID_RESERVATION_LOCK, 2, sub {
	my $reservation_list = $parse_pci_reservation_unlocked->();
	delete $reservation_list->@{$dropped_ids->@*};
	$write_pci_reservation_unlocked->($reservation_list);
    });
    die $@ if $@;
}

sub reserve_pci_usage {
    my ($requested_ids, $vmid, $timeout, $pid) = @_;

    $requested_ids = [ $requested_ids ] if !ref($requested_ids);
    return if !scalar(@$requested_ids); # do nothing for empty list

    PVE::Tools::lock_file($PCIID_RESERVATION_LOCK, 5, sub {
	my $reservation_list = $parse_pci_reservation_unlocked->();

	my $ctime = time();
	for my $id ($requested_ids->@*) {
	    my $reservation = $reservation_list->{$id};
	    if ($reservation && $reservation->{vmid} != $vmid) {
		# check time based reservation
		die "PCI device '$id' is currently reserved for use by VMID '$reservation->{vmid}'\n"
		    if defined($reservation->{time}) && $reservation->{time} > $ctime;

		if (my $reserved_pid = $reservation->{pid}) {
		    # check running vm
		    my $running_pid = PVE::QemuServer::Helpers::vm_running_locally($reservation->{vmid});
		    if (defined($running_pid) && $running_pid == $reserved_pid) {
			die "PCI device '$id' already in use by VMID '$reservation->{vmid}'\n";
		    } else {
			warn "leftover PCI reservation found for $id, lets take it...\n";
		    }
		}
	    }

	    $reservation_list->{$id} = { vmid => $vmid };
	    if (defined($pid)) { # VM started up, we can reserve now with the actual PID
		$reservation_list->{$id}->{pid} = $pid;
	    } elsif (defined($timeout)) { # tempoaray reserve as we don't now the PID yet
		$reservation_list->{$id}->{time} = $ctime + $timeout + 5;
	    }
	}
	$write_pci_reservation_unlocked->($reservation_list);
    });
    die $@ if $@;
}

1;
