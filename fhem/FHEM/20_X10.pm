################################################################
#
#  Copyright notice
#
#  (c) 2008 Dr. Boris Neubert (omega@online.de)
#
#  This script is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  This copyright notice MUST APPEAR in all copies of the script!
#
################################################################

package main;

use strict;
use warnings;

my %functions  = (  ALL_UNITS_OFF           => "all_units_off",
                    ALL_LIGHTS_ON           => "all_lights_on",
                    ON                      => "on",
                    OFF                     => "off",
                    DIM                     => "dimdown",
                    BRIGHT                  => "dimup",
                    ALL_LIGHTS_OFF          => "all_lights_off",
                    EXTENDED_CODE           => "",
                    HAIL_REQUEST            => "",
                    HAIL_ACK                => "",
                    PRESET_DIM1             => "",
                    PRESET_DIM2             => "",
                    EXTENDED_DATA_TRANSFER  => "",
                    STATUS_ON               => "",
                    STATUS_OFF              => "",
                    STATUS_REQUEST          => "",
                );

my %snoitcnuf;  # the reverse of the above

my %functions_rewrite = ( "all_units_off"  => "off",
                          "all_lights_on"  => "on",
                          "all_lights_off" => "off",
                        );

my %functions_snd = qw(  ON  0010
                         OFF 0011
                         DIM 0100
                         BRIGHT 0101 );

my %housecodes_snd = qw(A 0110  B 1110  C 0010  D 1010
                        E 0001  F 1001  G 0101  H 1101
                        I 0111  J 1111  K 0011  K 1011
                        M 0000  N 1000  O 0100  P 1100);

my %unitcodes_snd  = qw( 1 0110   2 1110   3 0010   4 1010
                         5 0001   6 1001   7 0101   8 1101
                         9 0111  10 1111  11 0011  12 1011
                        13 0000  14 1000  15 0100  16 1100);


my %functions_set = ( "on"      => 0,
                      "off"     => 0,
                      "dimup"   => 1,
                      "dimdown" => 1,
                      "on-till" => 1,
                    );

# devices{HOUSE}{UNIT} -> Pointer to hash for the device for lookups
my %devices;

my %models = (
    lm12	=> 'dimmer',
    lm15        => 'simple',
    am12        => 'simple',
    tm13        => 'simple',
);

my @lampmodules = ('lm12','lm15'); # lamp modules


sub
X10_Initialize($)
{
  my ($hash) = @_;

  foreach my $k (keys %functions) {
    $snoitcnuf{$functions{$k}}= $k;
  }

  $hash->{Match}     = "^X10:[A-P];";
  $hash->{SetFn}     = "X10_Set";
  $hash->{StateFn}   = "X10_SetState";
  $hash->{DefFn}     = "X10_Define";
  $hash->{UndefFn}   = "X10_Undef";
  $hash->{ParseFn}   = "X10_Parse";
  $hash->{AttrList}  = "IODev follow-on-for-timer:1,0 do_not_notify:1,0 dummy:1,0 showtime:1,0 model:lm12,lm15,am12,tm13 loglevel:0,1,2,3,4,5,6";

}

#####################################
sub
X10_SetState($$$$)
{
  my ($hash, $tim, $vt, $val) = @_;
  return undef;
}

#############################
sub
X10_Do_On_Till($@)
{
  my ($hash, @a) = @_;
  return "Timespec (HH:MM[:SS]) needed for the on-till command" if(@a != 3);

  my ($err, $hr, $min, $sec, $fn) = GetTimeSpec($a[2]);
  return $err if($err);

  my @lt = localtime;
  my $hms_till = sprintf("%02d:%02d:%02d", $hr, $min, $sec);
  my $hms_now = sprintf("%02d:%02d:%02d", $lt[2], $lt[1], $lt[0]);
  if($hms_now ge $hms_till) {
    Log 4, "on-till: won't switch as now ($hms_now) is later than $hms_till";
    return "";
  }

  my @b = ($a[0], "on");
  X10_Set($hash, @b);
  CommandDefine(undef, $hash->{NAME} . "_till at $hms_till set $a[0] off");

}

###################################

sub
X11_Write($$$)
{
  my ($hash, $function, $dim)= @_;
  my $name     = $hash->{NAME};
  my $housecode= $hash->{HOUSE};
  my $unitcode = $hash->{UNIT};
  my $x10func  = $snoitcnuf{$function};
  undef $function; # do not use after this point
  my $prefix= "X10 device $name:";

  Log 5, "$prefix sending X10:$housecode;$unitcode;$x10func $dim";

  my ($hc_b, $hu_b, $hf_b);
  my ($hc, $hu, $hf);

  # Header:Code, Address
  $hc_b  = "00000100"; # 0x04
  $hc    = pack("B8", $hc_b);
  $hu_b  = $housecodes_snd{$housecode} . $unitcodes_snd{$unitcode};
  $hu    = pack("B8", $hu_b);
  IOWrite($hash, $hc, $hu);

  # Header:Code, Function
  $hc_b   = substr(unpack('B8', pack('C', $dim)), 3) . # dim, 0..22
            "110";                                     # always 110
  $hc     = pack("B8", $hc_b);
  $hf_b   = $housecodes_snd{$housecode} . $functions_snd{$x10func};
  $hf     = pack("B8", $hf_b);
  IOWrite($hash, $hc, $hf);
}

###################################
sub
X10_Set($@)
{
  my ($hash, @a) = @_;
  my $ret = undef;
  my $na = int(@a);

  # initialization and sanity checks
  return "no set value specified" if($na < 2);

  my $name= $hash->{NAME};
  my $function= $a[1];
  my $nrparams= $functions_set{$function};
  return "Unknown argument $function, choose one of " .
          join(",", sort keys %functions_set) if(!defined($nrparams));
  return "Wrong number of parameters"  if($na != 2+$nrparams);

  # special for on-till
  return X10_Do_On_Till($hash, @a) if($function eq "on-till");

  # argument evaluation
  my $model= $hash->{MODEL};

  my $dim= 0;
  if($function =~ m/^dim/) {
    return "Cannot dim $name (model $model)" if($models{$model} ne "dimmer");
    my $arg= $a[2];
    return "Wrong argument $arg, use 0..22" if($arg !~ m/^[0-9]{1,2}$/);
    return "Wrong argument $arg, use 0..22" if($arg>22);
    $dim= $arg;
  }

  # send command to CM11
  X11_Write($hash, $function, $dim) if(!IsDummy($a[0]));

  my $v = join(" ", @a);
  Log GetLogLevel($a[0],2), "X10 set $v";
  (undef, $v) = split(" ", $v, 2);      # Not interested in the name...

  my $tn = TimeNow();

  $hash->{CHANGED}[0] = $v;
  $hash->{STATE} = $v;
  $hash->{READINGS}{state}{TIME} = $tn;
  $hash->{READINGS}{state}{VAL} = $v;

  return undef;
}

#############################
sub
X10_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  return "wrong syntax: define <name> X10 model housecode unitcode"
                if(int(@a)!= 5);

  my $model= $a[2];
  return "Define $a[0]: wrong model: specify one of " .
            join ",", sort keys %models
                if(!grep { $_ eq $model} keys %models);

  my $housecode = $a[3];
  return "Define $a[0]: wrong housecode format: specify a value ".
         "from A to P"
  		if($housecode !~ m/^[A-P]$/i);

  my $unitcode = $a[4];
  return "Define $a[0]: wrong unitcode format: specify a value " .
         "from 1 to 16"
  		if( ($unitcode<1) || ($unitcode>16) );


  $hash->{MODEL}  = $model;
  $hash->{HOUSE}  = $housecode;
  $hash->{UNIT}   = $unitcode;

  if(defined($devices{$housecode}{$unitcode})) {
    return "Error: duplicate X10 device $housecode $unitcode definition " .
           $hash->{NAME} . " (previous: " .
           $devices{$housecode}{$unitcode}->{NAME} .")";
  }

  $devices{$housecode}{$unitcode}= $hash;

  AssignIoPort($hash);
}

#############################
sub
X10_Undef($$)
{
  my ($hash, $name) = @_;
  if( defined($hash->{HOUSE}) && defined($hash->{UNIT}) ) {
    delete($devices{$hash->{HOUSE}}{$hash->{UNIT}});
  }
  return undef;
}

#############################
sub
X10_Parse($$)
{
  my ($hash, $msg) = @_;

  # message example: X10:N;1 12;OFF
  (undef, $msg)= split /:/, $msg, 2; # strip off "X10"
  my ($housecode,$unitcodes,$command)= split /;/, $msg, 4;

  my @list;   # list of selected devices

  #
  # command evaluation
  #
  my ($x10func,$arg)= split / /, $command, 2;
  my $function= $functions{$x10func}; # translate, eg BRIGHT -> dimup
  undef $x10func; # do not use after this point

  # the following code sequence converts an all on/off command into
  # a sequence of simple on/off commands for all defined devices
  my $all_lights= ($function=~ m/^all_lights_/);
  my $all_units= ($function=~ m/^all_units_/);
  if($all_lights || $all_units) {
    $function= $functions_rewrite{$function}; # translate, all_lights_on -> on
    $unitcodes= "";
    foreach my $unitcode (keys %{ $devices{$housecode} } ) {
      my $h= $devices{$housecode}{$unitcode};
      my $islampmodule= grep { $_ eq $h->{MODEL} } @lampmodules;
      if($all_units || $islampmodule ) {
        $unitcodes.= " " if($unitcodes ne "");
        $unitcodes.= $h->{UNIT};
      }
    }
    # no units for that housecode
    if($unitcodes eq "") {
      Log 3, "X10 No units with housecode $housecode, command $command, " .
             "please define one";
      push(@list,
      "UNDEFINED X10 device $housecode ?, command $command");
      return @list;
    }
  }

  # apply to each unit in turn
  my @unitcodes= split / /, $unitcodes;

  if(!int(@unitcodes)) {
    # command without unitcodes, this happens when a single on/off is sent
    # but no unit was previously selected
    Log 3, "X10 No unit selected for housecode $housecode, command $command";
    push(@list,
    "UNDEFINED X10 device $housecode ?, command $command");
    return @list;
  }

  # function rewriting
  my $value= $function;
  return @list if($value eq "");  # function not evaluated

  # function determined, add argument
  if( defined($arg) ) {
    # received dims from 0..210
    my $dim= $arg;
    $value = "$value $dim" ;
  }


  my $unknown_unitcodes= '';
  foreach my $unitcode (@unitcodes) {
    my $h= $devices{$housecode}{$unitcode};
    if($h) {
        my $name= $h->{NAME};
        $h->{CHANGED}[0] = $value;
        $h->{STATE} = $value;
        $h->{READINGS}{state}{TIME} = TimeNow();
        $h->{READINGS}{state}{VAL} = $value;
        Log GetLogLevel($name,2), "X10 $name $value";
        push(@list, $name);
    } else {
        Log 3, "X10 Unknown device $housecode $unitcode, command $command, " .
               "please define it";
        push(@list,
        "UNDEFINED X10 device $housecode $unitcode, command $command");
    }
  }
  return @list;

}


1;
