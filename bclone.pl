#!/usr/bin/perl

package Net::BitBucket;
use strict;
use warnings;
use constant UA_TIMEOUT => 10;
use LWP::UserAgent;
use JSON;
use Carp qw(croak);

use constant URL      => 'https://api.bitbucket.org/1.0/users/%s/';
use constant BASE_URL => 'https://bitbucket.org/%s/%s/';

our $VERSION = '0.10';

my $UA = LWP::UserAgent->new;
$UA->agent(sprintf '%s/%s', __PACKAGE__, $VERSION);
$UA->env_proxy;
$UA->timeout(UA_TIMEOUT);

sub new { return bless {}, shift };

sub agent { return $UA }

sub get {
    my $self = shift;
    my $url  = shift;
    my $r    = $self->agent->get($url);

    if ( $r->is_success ) {
        my $raw = $r->decoded_content;
        return JSON::from_json( $raw );
    }

    croak( 'GET request failed: ' . $r->as_string );
}

sub repositories {
    my $self = shift;
    my $user = shift || croak 'No user name specified';
    warn ">> Fetching the base URL ...\n";
    my $raw  = eval { $self->get( sprintf URL, $user ) };
    croak "$user is not a valid user. Error: $@" if $@;
    croak "Data set is not a hash but $raw" if ref $raw ne 'HASH';
    my $r = $raw->{repositories} || die "No 'repositories' key in resultset";
    my @repos = sort { $a->{name} cmp $b->{name} }
                map { {
                    name => $_->{name},
                    url  => sprintf( BASE_URL, $user, $_->{slug} ),
                }}
                @{ $r };
    return @repos;
}

package main;
use strict;
use warnings;
use File::Spec;
use Data::Dumper;
use File::Path;
use Time::HiRes qw( time );
use constant RE_CPAN   => qr{ \A (CPAN) \- (.+?) \z }xms;
use constant SEPERATOR => join q{},  q{-} x 80, "\n";
use Cwd;
use Carp qw( croak );

my $CWD   = getcwd;
my $START = time;
my $bit   = Net::BitBucket->new;

_w( "CURRENT DIRECTORY: $CWD\n",
    "STARTING TO CLONE REPOSITORIES FROM BURAK GURSOY...\n",
    SEPERATOR );

my $total = 0;
foreach my $repo ( $bit->repositories( 'burak' ) ) {
    chdir $CWD; # reset

    my $name = $repo->{name};
    my @path = $name =~ RE_CPAN ? ($1, $2) : ($name);
    my $dir  = File::Spec->catdir( @path );

    if ( @path > 1 ) {
        mkpath $path[0];
        chdir  $path[0];
    }

    _w( "PROCESSING $name ...\n" );
    my $local_target = @path > 1 ? $path[1] : undef;

    if ( $local_target && -d $local_target ) {
        _w("$local_target exists. Skipping ...\n");
        next;
    }

    eval {
        hg( clone => $repo->{url}, $local_target ? ($local_target) : () );
        _w( "... done!\n", SEPERATOR );
        1;
    } or do {
        my $e = $@ || '[unknown error]';
        die $@; # rollback && next?
    };
    $total++;
}

_w( "ADDED %d REPOSITORIES IN %.4f SECONDS\n", $total, time - $START );

sub _w {
    my @args = @_;
    printf {*STDERR} @args or croak "Unable to print to STDERR: $!";
    return;
}

sub hg {
    my @args = @_;
    system( hg => @args ) && croak "FAILED(@args): $?";
    return;
}

1;

__END__

=pod

=head1 NAME

bclone.pl - Get all stuff from Burak Gursoy

=head1 SYNOPSIS

   chdir projects
   perl bclone.pl

=head1 AUTHOR

Burak Gursoy.

=cut
