#!/usr/bin/perl
# Captur's narrow entry point for the BSD-licensed MediaRemote Adapter.
use strict;
use warnings;
use DynaLoader;
$| = 1;
my ($framework, $command) = @ARGV;
die "Expected framework and get/pause/play\n" unless @ARGV == 2 && defined $framework
  && defined $command && ($command eq 'get' || $command eq 'pause' || $command eq 'play');
my $library = "$framework/CapturMediaRemoteAdapter";
die "Missing adapter\n" unless -f $library;
$ENV{'MEDIAREMOTEADAPTER_OPTION_no_artwork'} = '';
my $handle = DynaLoader::dl_load_file($library, 0) or die "Cannot load adapter\n";
my $symbol = $command eq 'get' ? 'adapter_get_env' : 'captur_guarded_command';
$ENV{'CAPTUR_MEDIA_COMMAND'} = $command;
my $address = DynaLoader::dl_find_symbol($handle, $symbol) or die "Missing entry point\n";
DynaLoader::dl_install_xsub('main::invoke', $address);
invoke();
