#!/usr/bin/perl -w
# 
# This is a mostly intact perl script from
#
# https://github.com/timothyh/mochad-mqtt/tree/master
#
# The original code only sent and received PL powerline commands
# My changes are mainly to allow receiving and sending either RF or PL commands
# For RF devices, I prefix 99 to the unit number
# ie for RF HouseUnit A10 it is entered and stored as A9910 to distinguish it from the powerline HouseUnit A10
# also did a few changes to help make it work as a HA add-on.
#
#
#
#
#
# following are original comments from timothyh
#
# Drived from https://github.com/kevineye/docker-heyu-mqtt
#
# For Mochad commands see
# https://bfocht.github.io/mochad/mochad_reference.html
#
use strict;

use Data::Dumper;
use Time::HiRes qw(usleep sleep);
use POSIX qw(strftime);
use File::stat;

use File::Basename;

use AnyEvent;
use AnyEvent::MQTT;
use AnyEvent::Socket;
use AnyEvent::Strict;

use JSON::PP;

my $mm_config = $ENV{MM_CONFIG} || '/mochad-mqtt.json';

my @fromenv =
  qw(MQTT_HOST MQTT_PORT MQTT_USER MQTT_PASSWORD MQTT_PREFIX MOCHAD_HOST MOCHAD_PORT MM_TOTAL_INSTANCES MM_INSTANCE MM_DELAY);

my %config = (
    cache_dir             => './cache',
    hass_discovery_enable => 0,
    hass_id_prefix        => "x10",
    hass_retain           => 0,
    mm_total_instances    => 2,
    mm_instance           => 1,                     # Instance number - offset 1
    mm_delay              => 0.2,
    mqtt_host             => 'localhost',
    mqtt_port             => '1883',
    mqtt_prefix           => 'home/x10',
    mqtt_ping             => 'ping/home/x10/_ping',
    mqtt_idle             => 300.0,
    mochad_host           => 'localhost',
    mochad_port           => '1100',
    mochad_idle           => 300.0,
    passthru      => 0,    # Publish all input from Mochad
    passthru_send => 0,    # Allow commands to pass directly to Mochad
    perl_anyevent_log => 'filter=info',
    repeat_interval   => 1,
    slug_separator    => '-',
    verbose           => 0,
);

my @boolopts =
  qw(hass_discovery_enable hass_retain passthru passthru_send verbose);

my $verbose = 0;

# Mapping of input commands to Mochad usage
my %cmds = (
    on        => 'on',
    off       => 'off',
    unitson   => 'all_units_on',
    unitsoff  => 'all_units_off',
    allon     => 'all_units_on',
    alloff    => 'all_units_off',
    lightson  => 'all_lights_on',
    lightsoff => 'all_lights_off',
);

#
# Device types
# 1 == appliance - state recorded, responds to allunitson/off
# 2 == light - state recorded, responds to allunitson/off and alllightson/off
# 3 => sensor - state recorded, input only
# 4 => remote/scene controller - state not recorded, input only
#
my %types = (
    sensor    => 3,
    switch    => 1,
    light     => 2,
    remote    => 4,
);

# List of all lights
my %lights;

# List of all appliances, includes lights
my %appls;

# List of devices to ignore
my %ignore;

# house codes => alias
my %devcodes;

my %retain;

my %states;

# device names from mochad-mqtt.json => topics from mqtt
my %alias;

my $mqtt;
my $mqtt_updated;
my $mochad_updated;
my $config_updated;
my $config_mtime;

my $handle;

sub read_config_file {

    die "Unable to read config file: $mm_config\n"
      unless ( open CONFIG, '<' . $mm_config );
    my $conf_text = join( '', <CONFIG> );
    close CONFIG;
    my $conf = JSON::PP->new->decode($conf_text);

    unless ( $ENV{'AE_LOG'} || $ENV{'PERL_ANYEVENT_LOG'} ) {
        $ENV{'PERL_ANYEVENT_LOG'} = $conf->{'perl_anyevent_log'}
          if ( $conf->{'perl_anyevent_log'} );
    }

    %alias    = ();
    %devcodes = ();
    %appls    = ();
    %lights   = ();
    %retain   = ();

    for my $sect ( 'hass', 'mm', 'mochad', 'mqtt' ) {
        next unless ( exists $conf->{$sect} );
        my %tmp = %{ $conf->{$sect} };
        foreach my $key ( keys %tmp ) {
            $config{"${sect}_${key}"} = $tmp{$key};
        }
        delete $conf->{$sect};
    }

    for my $code ( @{ $conf->{'ignore'} } ) {
        unless ( $code =~ m{([A-Za-z])([\d,-]+)} ) {
            AE::log error => "Bad device definition: $code";
            next;
        }
        my $house = uc $1;
        my @codes = str_range($2);

        foreach my $i ( 0 .. scalar @codes ) {
            next unless ( $codes[$i] );

            $ignore{"$house$i"} = 1;
        }
    }
    delete $conf->{'ignore'};
    for my $alias ( keys %{ $conf->{'devices'} } ) {
        my $err = 0;
        if ( length($alias) <= 3 ) {
            AE::log error => "Name must be 4 chars or more: $alias";
            $err = 1;
        }
        my %tmp = %{ $conf->{devices}{$alias} };

        my $type = defined $tmp{'type'} ? lc $tmp{'type'} : '';
        $type = defined $types{$type} ? $types{$type} : 0;

        my $repeat = defined( $tmp{'repeat'} ) ? $tmp{'repeat'} : 0;
        if ( $repeat < 0 || $repeat > 9 ) {
            AE::log error => "$alias: Bad repeat value: $repeat";
            $err = 1;
        }

        my $retain = is_true( $tmp{'retain'} );

        my @devcodes;

        my @tmpcode = defined $tmp{'codes'} ? $tmp{'codes'} : ();
        push( @tmpcode, $tmp{'code'} ) if ( defined $tmp{'code'} );

        for my $code (@tmpcode) {
            $code = uc $code;
          unless ( $code =~ m{([A-Za-z])([\d,-]+)} ) {
                AE::log error => "$alias: Bad device definition: $code";
                $err = 1;
            }
            my $house = uc $1;
            my @codes = str_range($2);
           foreach my $i ( 0 .. scalar @codes ) {
                next unless ( $codes[$i] );
                push( @devcodes, $house . $i );
					
                if ( $type == 2 ) {
                    $lights{$house}{$i} = 1;
                    $appls{$house}{$i}  = 1;
                }
                elsif ( $type == 1 ) {
                    $appls{$house}{$i} = 1;
                }
            }
        }

        if ($err) {
            AE::log error => Dumper( \%tmp );
            next;
        }

        my $name = defined $tmp{'name'} ? $tmp{'name'} : $alias;
        $alias = lc $alias;
        $alias =~ s/[^0-9a-z]+/$config{slug_separator}/g;
        $alias{$alias} = {} unless defined $alias{$alias};
        $alias{$alias}{'codes'} = ();
        push( @{ $alias{$alias}{'codes'} }, sort @devcodes );

        $retain{$alias} = 1 if ($retain);
        $alias{$alias}{'retain'}       = $retain;
        $alias{$alias}{'name'}         = $name;
        $alias{$alias}{'type'}         = $type;
        $alias{$alias}{'repeat'}       = $repeat;
        $alias{$alias}{'device_class'} = $tmp{'device_class'}
          if ( defined $tmp{'device_class'} );

        for my $code (@devcodes) {
            $devcodes{$code} = $alias;
            $retain{$code} = 1 if ($retain);
        }

    }
    delete $conf->{'devices'};

    for my $attr ( keys %{$conf} ) {
        $config{$attr} = $conf->{$attr};
    }

############################################################################
	AE::log error => "jdbg: alias: " . Dumper( \%alias );
	AE::log error => "jdbg: devcodes: ".Dumper(\%devcodes);
	AE::log error => "jdbg: ignore: ".Dumper(\%ignore);
	AE::log error => "jdbg: retain: ".Dumper(\%retain);
	AE::log error => "jdbg: appliances: ".Dumper(\%appls);
	AE::log error => "jdbg: lights: " .Dumper(\%lights);
	AE::log error => "jdbg: config: " .Dumper(\%config);
    #
    #exit 0;
############################################################################

}

sub read_config {

    read_config_file();
    $config_mtime = stat($mm_config)->mtime;

    # Environment overrides config file
    foreach (@fromenv) {
        $config{ lc $_ } = $ENV{ uc $_ } || $config{ lc $_ };
    }

    # Standardize boolean options
    foreach (@boolopts) {
        $config{$_} = is_true( $config{$_} );
    }
    $config_updated = Time::HiRes::time;
    $verbose = 1 if ( $config{verbose} );

    AE::log debug => "Devices = " . join( ' ', sort( keys %alias ) );
}

sub changed_config {
    if ( stat($mm_config)->mtime > $config_mtime ) {
        AE::log alert => "Config file $mm_config changed";
        return 1;
    }
    return 0;
}

sub is_true {
    my ( $input, @special ) = @_;

    return 0 unless ( defined $input );

    if ( $input =~ /^\d+$/ ) {
        return 0 if ( $input == 0 );
        return 1;
    }

    $input = lc $input;

    for my $v ( 'true', 'on', @special ) {
        return 1 if ( $input eq $v );
    }

    for my $v ( 'false', 'off', @special ) {
        return 0 if ( $input eq $v );
    }

    AE::log error => "Invalid boolean: " . $input;

    return 0;
}

sub str_range {
    my ($str) = @_;

    my @arr;

    foreach ( split /,/, $str ) {
        if (/(\d+)-(\d+)/) {
            foreach ( $1 .. $2 ) { $arr[$_] = 1; }
        }
        elsif (/\d+/) { $arr[$_] = 1; }
    }
    return @arr;
}

sub mqtt_error_cb {
    my ( $fatal, $message ) = @_;
    AE::log error => $message;
    if ($fatal) {
        AE::log error => "Fatal error - exiting";
        exit(1);
    }
}

my @delay_timer;

sub delay_write {
    my ( $handle, $message, $repeat ) = @_;
    my $delay = 0.0;

    if ( defined( $config{mm_delay} ) && $config{mm_delay} > 0 ) {
        my $sum = $config{mm_instance} - 1;
        foreach my $ascval ( unpack( "C*", $message ) ) {
            $sum += $ascval;
        }

        $delay = $config{mm_delay} * ( $sum % $config{mm_total_instances} );

        AE::log debug =>
          "Instance => $config{mm_instance} Sum => $sum Delay => $delay";
    }

    for ( my $i = 0 ; $i <= $repeat ; $i++ ) {
        if ( $delay > 0.0 ) {
            my $timer_offset = scalar @delay_timer;
            $delay_timer[$timer_offset] = AnyEvent->timer(
                after => $delay,
                cb    => sub {
                    $handle->push_write($message);
                    delete $delay_timer[$timer_offset];
                }
            );
        }
        else {
            $handle->push_write($message);
        }
        $delay += $config{repeat_interval};
    }
}

sub receive_passthru_send {
    my ( $topic, $message ) = @_;

    $mqtt_updated = AnyEvent->now;

    chomp $message;

    if ( $config{passthru_send} ) {
        AE::log debug => "Received topic: \"$topic\" message: \"$message\"";

        AE::log info => "Passthru: Command => \"$message\"";
        delay_write( $handle, $message . "\r", 0 );
    }
    else {
        AE::log debug =>
          "Passthru disabled - Ignoring  \"$topic\" message: \"$message\"";
    }
    return;
}

sub receive_mqtt_ping {
    $mqtt_updated = AnyEvent->now;
}

sub receive_hass_startup {
    my ( $topic, $payload ) = @_;

    $mqtt_updated = AnyEvent->now;

    AE::log debug => "Received topic: \"$topic\" payload: \"$payload\"";

    chomp $payload;

    return unless ( lc($payload) eq lc( $config{hass_startup_payload} ) );

    AE::log info => "Home assistant restarted";

    hass_publish_all();
}

sub receive_mqtt_set {
    my ( $topic, $payload ) = @_;

    $mqtt_updated = AnyEvent->now;

    $topic =~ m{\Q$config{mqtt_prefix}\E/([^/]+)/set}i;
    my $device = lc $1;

    ( $device eq '_ping' ) && return;

    chomp $payload;
    $payload = lc $payload;

    AE::log debug => "Received topic: \"$topic\" payload: \"$payload\"";

    if ( $device eq 'passthru' ) {
        AE::log info => "Passthru set: Command => \"$payload\"";
        $config{passthru} = is_true($payload);
        return;
    }

    $device =~ s/[^0-9a-z]+/$config{slug_separator}/g;

    if ( defined $cmds{$payload} ) {
        if ( defined $alias{$device} ) {
            my $repeat = $alias{$device}{repeat};
            foreach ( @{ $alias{$device}{codes} } ) {
                unless ( $ignore{$_} ) {

					if ( $_ =~ m{([A-Z])99(\d+)}i ) {
						my $rfunit = uc $1;
						$rfunit = $rfunit.$2;
                   delay_write( $handle,
                        "rf " . $rfunit . ' ' . $cmds{$payload} . "\r", $repeat );
					}
				else {	
                    AE::log info =>
                      "Switching device $_ $payload => $cmds{$payload}";
                    delay_write( $handle,
                        "pl " . $_ . ' ' . $cmds{$payload} . "\r", $repeat );
					}	
                }
            }
        }
        elsif ( $device =~ m{^[a-z]\d*$} ) {
            $device = uc $device;
            unless ( $ignore{$device} ) {
                AE::log info =>
                  "Switching device $device $payload => $cmds{$payload}";
                delay_write( $handle, "pl $device $cmds{$payload}\r", 0 );
            }
        }
        else {
            AE::log error =>
              "Unknown device: \"$device\" payload: \"$payload\"";
        }
    }
    else {
        AE::log error =>
          "Unknown command: device: \"$device\" payload: \"$payload\"";
    }
}

sub load_state {
    return unless ( length $config{cache_dir} > 0 );

    my $cache = $config{cache_dir} . '/states.json';
    if ( open( FH, '<', $cache ) ) {
        my $text = join( '', <FH> );
        close FH;
        my $tmp = JSON::PP->new->decode($text);
        %states = %{$tmp} if ( defined $tmp );
    }
    else {
        AE::log error => "Unable to open $cache: $!";
    }
}

my $state_changed = 0;

sub save_state {
    my ( $device, $status ) = @_;

    $state_changed = 1
      unless ( exists $states{$device}
        && $states{$device}{state} eq $status->{state} );

    my %tmp;
    $tmp{state} = $status->{state};
    $tmp{timestamp} =
      defined $status->{timestamp}
      ? $status->{timestamp}
      : strftime( "%Y-%m-%dT%H:%M:%S", localtime );

    $states{$device} = \%tmp;
}

sub store_state {
    if ($state_changed) {
        if ( length $config{cache_dir} > 0 ) {
            my $cache = $config{cache_dir} . '/states.json';
            if ( open( FH, '>', $cache ) ) {
                print FH JSON::PP->new->utf8->canonical->pretty->encode(
                    \%states );
                close(FH);
            }
            else {
                AE::log error => "Unable to open $cache: $!";
            }
        }
    }
    $state_changed = 0;
}

my $prev_text = '';

sub send_mqtt_status {
    my ( $device, $status ) = @_;

    return if ( $ignore{$device} );

    my $json_text = JSON::PP->new->utf8->canonical->encode($status);

    # Simplistic duplicate suppression
    return if ( $json_text eq $prev_text );

    if ( defined( $status->{state} ) ) {

        # Short form
        send_mqtt_message( "$device/state", $status->{state}, 0 );
    }

    # Long form
    my $retain = $retain{$device} ? 1 : 0;

    AE::log debug => "$device retain: $retain";

    $prev_text = $json_text;

    $status->{timestamp} = strftime( "%Y-%m-%dT%H:%M:%S", localtime )
      unless ( defined $status->{timestamp} );

    my $text = JSON::PP->new->utf8->canonical->encode($status);
    send_mqtt_message( $device, $text, $retain );
}

sub send_mqtt_message {
    my ( $topic, $message, $retain ) = @_;

    $mqtt->publish(
        topic   => "$config{mqtt_prefix}/$topic",
        message => $message,
        retain  => $retain,
    );
}

my $addr_queue = {};

#01/21 13:29:09 Rx PL HouseUnit: L1
#01/21 13:29:10 Rx PL House: L Func: Off

sub process_x10_line {
    my ($input) = @_;

    $mochad_updated = AnyEvent->now;

    chomp $input;

    # Raw data received:
    # Needs --raw-data opion set in Mochad

    my $raw = 0;
    if ( $input =~ m{Raw data received:\s+([\s\da-f]+)$}i ) {
        $input = $1;
        $raw   = 1;
        AE::log debug => "Raw data: $input";
    }

    send_mqtt_message( 'passthru', $input, 0 ) if ( $config{passthru} );

    if ($raw) { }
    elsif ( $input =~ m{RF\sHouseUnit:\s+([A-Z])(\d+)\s+Func:\s+([\sa-z]+)}i ) {
        my $house = uc $1;
        my $unit  = $2;
		$unit = '99'.$unit;
        my $cmd   = lc $3;
        process_x10_cmd( $cmd, "$house$unit" );
    }
   elsif ( $input =~ m{ HouseUnit:\s+([A-Z])(\d+)}i ) {
        my $house = uc $1;
        my $unit  = $2;
        AE::log debug => "House=$house Unit=$unit";
        $addr_queue->{$house} ||= {};
        $addr_queue->{$house}{$unit} = 1;
    }
    elsif ( $input =~ m{ House:\s+([A-Z])\s+Func:\s+([\sa-z]+)}i ) {
        my $cmd   = lc $2;
        my $house = uc $1;

        AE::log debug => "House=$house Cmd=$cmd";
        if ( $cmd =~ m{^on$|^off$} ) {
            if ( $addr_queue->{$house} ) {
                for my $k ( keys %{ $addr_queue->{$house} } ) {
                    process_x10_cmd( $cmd, "$house$k" );
                }
                delete $addr_queue->{$house};
            }
        }
        elsif ( $cmd =~ m{all\s+(\w+)\s+(\w+)} ) {
            process_x10_cmd( "$1$2", $house );
        }
    }
    else {
        AE::log error => "Unmatched: $input";
    }
}

sub process_x10_cmd {
    my ( $cmd, $device ) = @_;

    AE::log info => "processing $device: $cmd";

    $cmd    = lc $cmd;
    $device = lc $device;

    unless ( defined $cmds{$cmd} ) {
        AE::log error => "unexpected command $device: $cmd";
        return;
    }

    if ( $ignore{ uc $device } ) {
        AE::log debug => "ignoring command $device: $cmd";
    }
    elsif ( $device =~ m{^([a-z])(\d+)$} ) {
        my %status;
        my $house    = uc $1;
        my $unitcode = $2;

        $status{'house'}    = $house;
        $status{'unitcode'} = $unitcode;
        $status{'state'}    = $cmd;
        $status{'command'}  = $cmd;
        $status{'instance'} = $config{mm_instance};

        my $alias;
        my $type = 0;
        if ( defined $devcodes{ uc $device } ) {
            $alias = $devcodes{ uc $device };
            $status{'alias'} = $alias;
            my %tmp = %{ $alias{$alias} };
            $type = defined $tmp{type} ? $tmp{type} : 0;
        }
        else {
            $alias = $device;
        }
        send_mqtt_status( $alias, \%status );
        if ( $type == 1 || $type == 2 || $type == 3 ) {
            save_state( $alias, \%status );
            store_state();
        }
    }
    elsif ( $device =~ m{^[a-z]$} ) {
        my %status;
        my $house = uc $device;

        $status{'house'}    = $house;
        $status{'command'}  = $cmd;
        $status{'instance'} = $config{mm_instance};

        send_mqtt_status( $house, \%status, 0 );

        if ( $cmd =~ m{off$} ) {
            $status{'state'} = 'off';
        }
        else {
            $status{'state'} = 'on';
        }
        my @unitcodes;
        if ( $cmd =~ m{lights} ) {
            @unitcodes = sort( { $a <=> $b } keys %{ $lights{$house} } );
        }
        else {
            @unitcodes = sort( { $a <=> $b } keys %{ $appls{$house} } );
        }

        my %published;
        for my $i (@unitcodes) {
            $status{'unitcode'} = $i;
            my $device = "$house$i";
            my $alias =
              defined $devcodes{$device} ? $devcodes{$device} : $device;
            next if ( $published{$alias} );
            $status{'alias'} = $alias;

            send_mqtt_status( $alias, \%status );
            save_state( $alias, \%status );

            $published{$alias} = 1;
        }
        store_state();
    }
    else {
        AE::log error => "unexpected $device: $cmd";

        return;
    }
}

sub hass_publish_all() {
    for my $alias ( sort( keys %alias ) ) {
        my %tmp = %{ $alias{$alias} };

        my $type = defined $tmp{type} ? $tmp{type} : 0;
        my $hass_type = '';

        if    ( $type == 1 ) { $hass_type = 'switch'; }
        elsif ( $type == 2 ) { $hass_type = 'light'; }
        elsif ( $type == 3 ) { $hass_type = 'binary_sensor'; }
        elsif ( $type == 4 ) { next; }
        else                 { next; }

        my $id = $config{hass_id_prefix} . '.' . $hass_type . '.' . $alias;

        my %attr = (
            device => {
                identifiers => $id,
                name        => $tmp{name}
            },
            name        => $tmp{name},
            payload_off => 'off',
            payload_on  => 'on',
            state_topic => $config{mqtt_prefix} . '/' . $alias . '/state',
            unique_id   => $id
        );

        if ( $type == 1 || $type == 2 ) {
            $attr{command_topic} = $config{mqtt_prefix} . '/' . $alias . '/set';
        }
        $attr{device_class} = $tmp{'device_class'}
          if ( defined $tmp{'device_class'} );

        $mqtt->publish(
            topic => $config{hass_topic_prefix} . '/'
              . $hass_type . '/'
              . $alias
              . '/config',
            message => JSON::PP->new->utf8->canonical->encode( \%attr ),
            retain  => $config{hass_retain},
        );
    }
    foreach my $code ( keys %devcodes ) {
        my $alias = $devcodes{$code};
        if ( exists $states{$alias} ) {
            my %tmp = %{ $alias{$alias} };
            my $type = defined $tmp{type} ? $tmp{type} : 0;

            if ( $type == 1 || $type == 2 || $type == 3 || $type == 4 ) {
                my %status;
                $status{alias}     = $alias;
                $status{timestamp} = $states{$alias}{timestamp};
                $status{state}     = $states{$alias}{state};
                $status{instance}  = $config{mm_instance};
                send_mqtt_status( $alias, \%status );
            }
        }
    }

}

########################################################################

read_config();
load_state();

$mqtt = AnyEvent::MQTT->new(
    host             => $config{mqtt_host},
    port             => $config{mqtt_port},
    user_name        => $config{mqtt_user},
    password         => $config{mqtt_password},
    on_error         => \&mqtt_error_cb,
    keep_alive_timer => 60,
);

$mqtt->subscribe(
    topic    => "$config{mqtt_prefix}/+/set",
    callback => \&receive_mqtt_set
  )->cb(
    sub {
        AE::log note => "subscribed to MQTT topic $config{mqtt_prefix}/+/set";
    }
  );

if ( $config{'mqtt_idle'} > 0.0 ) {
    $mqtt->subscribe(
        topic    => "$config{mqtt_ping}",
        callback => \&receive_mqtt_ping,
      )->cb(
        sub {
            AE::log note => "subscribed to MQTT topic $config{mqtt_ping}";
        }
      );
}

if ( $config{passthru_send} ) {
    $mqtt->subscribe(
        topic    => "$config{mqtt_prefix}/passthru/send",
        callback => \&receive_passthru_send,
      )->cb(
        sub {
            AE::log note =>
              "subscribed to MQTT topic $config{mqtt_prefix}/passthru/send";
        }
      );
}

if ( $config{hass_discovery_enable} ) {
    $mqtt->subscribe(
        topic    => "$config{hass_status_topic}",
        callback => \&receive_hass_startup,
      )->cb(
        sub {
            AE::log note =>
              "subscribed to MQTT topic $config{hass_status_topic}";
            hass_publish_all();
        }
      );
}

AE::log debug => Dumper( \%config );

# first, connect to the host
$handle = new AnyEvent::Handle
  connect  => [ $config{'mochad_host'}, $config{'mochad_port'} ],
  on_error => sub {
    my ( $hdl, $fatal, $msg ) = @_;
    AE::log error => $msg;
    if ($fatal) {
        AE::log error => "Fatal error - exiting";
        exit(1);
    }
  },
  keepalive => 1,
  no_delay  => 1;

$handle->on_read(
    sub {
        for ( split( /[\n\r]/, $_[0]->rbuf ) ) {
            next unless length $_;

            AE::log debug => "Received line: \"$_\"";
            process_x10_line($_);
        }
        $_[0]->rbuf = "";
    }
);

# Watch config file for changes

AE::log debug => "Watch config file $mm_config";

my $conf_monitor = AnyEvent->timer(
    after    => 30.0,
    interval => 60.0,
    cb       => sub {
        if ( changed_config() ) {
            AE::log error => "$mm_config updated - Exiting";

            # Safer to just restart
            exit(10);
        }
    },
);

$mqtt_updated = AnyEvent->now;
my $mqtt_health;
if ( $config{'mqtt_idle'} > 0.0 ) {
    $mqtt_health = AnyEvent->timer(
        after    => 0.1,
        interval => ( $config{'mqtt_idle'} / 2.0 ) - 1.0,
        cb       => sub {
            my $inactivity = AnyEvent->now - $mqtt_updated;
            if ( $inactivity >= ( $config{'mqtt_idle'} - 0.2 ) ) {
                AE::log error =>
                  "No MQTT activity for $inactivity secs. Exiting";
#                exit(0);
            }
            $mqtt->publish(
                topic   => "$config{mqtt_ping}",
                retain  => 0,
                message => '{"instance":"'
                  . $config{mm_instance}
                  . '","timestamp":"'
                  . strftime( "%Y-%m-%dT%H:%M:%S", localtime ) . '"}',
            );
        },
    );
}

$mochad_updated = AnyEvent->now;
my $mochad_health;
if ( $config{'mochad_idle'} > 0.0 ) {
    $mochad_health = AnyEvent->timer(
        after    => 0.2,
        interval => ( $config{'mochad_idle'} / 2.0 ) - 1.0,
        cb       => sub {
            my $inactivity = AnyEvent->now - $mochad_updated;
            if ( $inactivity >= ( $config{'mochad_idle'} - 0.2 ) ) {
                AE::log error =>
                  "No mochad activity for $inactivity secs. Exiting";
#                exit(0);
            }
        },
    );
}

$handle->push_write("rftopl 0\r");

# use a condvar to return results
my $cv = AnyEvent->condvar;

$cv->recv;
