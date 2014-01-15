#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw( getcwd );
use File::Basename;
use File::Spec::Functions qw( canonpath catdir );
use Carp qw( croak );
use Getopt::Long;
use IO::Handle;

STDOUT->autoflush;
STDERR->autoflush;
STDIN->autoflush;

GetOptions(\my %OPT, qw(
    diff
    color
    commit
    push
    update
    pull
    all
));

RUN: {
    if ( $OPT{all} ) {
        $OPT{$_} = 1 for qw( diff color commit push );
    }
    $OPT{color} = 0 if $^O =~ m{\AMSWin}xms;
    my $base = shift || do {
        my $dn = dirname( __FILE__ );
        my $d  = canonpath( $dn );
        my $cwd = getcwd;
        chdir $d;
        chdir q(..);
        $d = getcwd;
        chdir $cwd;
        $d;
    };

    _p("BASE: $base - " . __FILE__ . "\n");

    opendir DIR, $base or croak "Can't opendir($base): $!";
    while ( my $dir = readdir DIR ) {
        next if $dir =~ m{\A[.]}xms;
        my $target = catdir $base, $dir;
        my $git_dir = catdir $target, '.git';
        next if ! -d $git_dir;
        visit( $target );
    }
    closedir DIR;
    _p("Finished!\n");
}

sub visit {
    my $dir = shift;
    my $prev = getcwd;
    chdir $dir;
    my $status;
    my $ok = eval {
        $status = qx{git status}; ## no critic (ProhibitBacktickOperators)
        1;
    };
    if ( $ok ) {
        if ( $status ) {
            _p("[DIR] $dir\n");
            my @lines = split m{\n}xms, $status;
            _p("\t$_\n") for @lines;
            if ( $OPT{diff} ) {
                my $cmd = q(git diff);
                $cmd .= q( | colordiff) if $OPT{color};
                system $cmd;
            }
            if ( $OPT{commit} ) {
                system git => 'commit';
            }
        }
    }
    else {
        _p("Error fetching status: $@\n");
    }

    foreach my $cmd ( qw( push pull update ) ) {
        system git => $cmd if $OPT{$cmd};
    }

    chdir $prev;
    return;
}

sub _p {
    my @args = @_;
    printf {*STDOUT} @args or croak "Unable to print to STDERR: $!";
    return;
}

1;

__END__
