#!/usr/bin/perl
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
use Net::GitHub;

my $CWD   = getcwd;
my $START = time;

my $g = Net::GitHub->new;
my @urls = map $_->{clone_url}, $g->repos->list_user( 'burak' );

_w( "CURRENT DIRECTORY: $CWD\n",
    "STARTING TO CLONE REPOSITORIES FROM BURAK GURSOY...\n",
    SEPERATOR );

my $total = 0;
foreach my $repo ( @urls ) {
    chdir $CWD; # reset

    my $name = $repo;
    $name =~ s{.*/}{}xms;
    $name =~ s{[.]git\z}{}xms;
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
        git( clone => $repo, $local_target ? ($local_target) : () );
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

sub git {
    my @args = @_;
    system( git => @args ) && croak "FAILED(@args): $?";
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
