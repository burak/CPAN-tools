#!/usr/bin/perl
package Burak::Build; ## no critic (Modules::RequireFilenameMatchesPackage)
use strict;
use warnings;
use utf8;

use Carp qw(croak confess);
use Cwd;
use Encode;
use File::Basename qw( dirname );
use File::Copy;
use File::Find;
use File::HomeDir;
use File::Path;
use File::Spec::Functions qw( catfile catdir );
use File::Temp qw( tempfile tempdir );
use Getopt::Long;
use Time::HiRes qw( time );
use Text::Template::Simple;

use constant {
    IS_WINDOWS         => $^O =~ m{ \A MSWin }xmsi ? 1 : 0,
    IS_OSX             => $^O eq 'darwin'          ? 1 : 0,
    BURAK_BUILD_BASE   => $ENV{BURAK_BUILD_BASE},
    MAX_MODNAME_LENGTH => 3,
    RAMGB              => 1024**2,
    BASE_DIR           => dirname( __FILE__ ),
};

use lib catdir( BASE_DIR, qw( builder builder lib ) );
use Build::Util qw( slurp );

BEGIN {
    if ( ! defined &_print ) {
        *_print = sub {
            # has to be here, putting this outside makes it a no-op
            # for some weird reason
            binmode STDOUT, ':encoding(utf-8)' if ! IS_WINDOWS;
            print @_ or croak "Unable to print to STDOUT: $!";
        };
    }

    *_error = sub { croak @_ }
        if ! defined &_error;
}

BEGIN { $| = 1; }

our $VERSION = q(1.20);

our $MAKE = IS_WINDOWS ? 'dmake' : 'make';
our($LANG, $LANG_ID) = load_lang();

our $TTS  = Text::Template::Simple->new(
    header => 'my %p = @_;',
    cache  => 1,
);

sub tts {
    my @args = @_;
    return $TTS->compile( @args );
}

GetOptions( \my %O => qw(
    keep
    nomb
    nomm
    install
    sudo
    module=i
    perl=s
));

$O{keep} ||= 0;

my $PERL_EXE = $O{perl} ? do {
    my $p = $O{perl};
    die "perl parameter is not a file\n" if ! -e $p;
    # TODO: more checks
    $p
} : $^X;

#--------------------------------------------------------------#

my( %path, $target, $modname, $source_dir, $START_TIME, $ALIEN );

run();

END {
    my $eok = eval { require Time::Elapsed; 1; };
    my $t   = $START_TIME ? time - $START_TIME : 0;
    $@ ? _print( sprintf L('bench.error'), $t )
       : _print( sprintf L('bench.ok'), Time::Elapsed::elapsed( $t, $LANG_ID ) );
    system q(echo "\033]0;\007\c") if IS_OSX;
}

sub L {
    my $id = shift;
    return $LANG->{$id};
}

sub run {

    if ( IS_WINDOWS ) {
        system title => sprintf '%sv%s', __PACKAGE__, $VERSION;
    }

    if ( IS_OSX ) {
        system sprintf q(echo "\033]0;%s v%s\007\c"), __PACKAGE__, $VERSION;
    }

    _print sprintf L('start.message'), __PACKAGE__, $VERSION;
    my $eok = eval { hello(); 1; };

    %path = get_path();
    ( $target, $modname ) = ask();

    $START_TIME = time;
    $source_dir = catfile( $path{source}, $target );
    $ALIEN      = ! -e catfile( $source_dir, 'SPEC' );

    duplicate();
    build();
    copy_dist();
    finish();

    return;
}

sub finish {
    _chdir( $path{cwd} ) if $path{cwd}; # return home to delete tempdir()
    _print tts(
        L('finish.report'),
        [
            source     => $path{source},
            source_dir => $source_dir,
            build      => $path{build},
            keep       => $O{keep},
            archive    => $path{archive},
            cwd        => $path{cwd},
        ]
    );

    return;
}

sub get_path {
    my %p = (
        source  => catfile( BURAK_BUILD_BASE, qw( CPAN ) ),
        build   => tempdir( CLEANUP => $O{keep} ? 0 : 1 ),
        archive => File::HomeDir->my_desktop,
        cwd     => catdir(cwd),
        tools   => catfile( BURAK_BUILD_BASE, qw( CPAN tools ) ),
        builder => catfile( BURAK_BUILD_BASE, qw( CPAN tools builder ) ),
    );

    if ( ! -e $p{source} ) {
        _error tts( L('get_path.source'),  [ source  => $p{source}  ] );
    }

    if ( ! -e $p{build} ) {
        _error tts( L('get_path.build'),   [ build   => $p{build}   ] );
    }

    if ( ! -e $p{archive} ) {
        _error tts( L('get_path.archive'), [ archive => $p{archive} ] );
    }

    return %p;
}

sub duplicate {
    _chdir($source_dir);
    my ( @dir, @file );
    find {
        wanted => sub {
            return if ! $_ || $_ =~ m{ \A [.]/[.] }xms;
            -d $_ ? push @dir, catdir($_) : push @file, catfile($_);
        },
        no_chdir => 1,
    }, q{.};

    my @bfile;
    if ( ! $ALIEN ) {
        _chdir( catdir $path{builder} );
        find {
            wanted => sub {
                return if ! $_ || $_ eq q{.};
                ( my $bare = catfile $_);
                $bare =~ s{ \A [\\/]+    }{}xms;
                $bare =~ s{    [\\/]+ \z }{}xms;
                -d $_ ? do { push @dir, $bare if $bare }
                      : push @bfile, catfile($_);
            },
            no_chdir => 1,
        }, q{.};
    }

    _chdir( $path{build} );
    mkpath \@dir;

    foreach my $file (@file) {
        next if copy( catfile( $path{source}, $target, $file ), $file );
        _error tts( L('duplicate.copy'), [ file => $file, error => $! ] );
    }

    if ( ! $ALIEN ) {
        _print "[DEBUG] INTEGRATING BUILD FILES \n";
        foreach my $file (@bfile) {
            my $source = catfile( $path{builder}, $file );
            copy( $source, $file ) or
               _error tts( L('duplicate.copy'), [ file => $file, error => $! ] );
        }
    }

    my %manifest = _manifest_to_hash();

    foreach my $bf (@bfile) {
        $bf =~ s{\\}{/}xmsg;
        write_file( '>>', MANIFEST => "$bf\n" ) if ! $manifest{ $bf };
    }
    return;
}

sub _manifest_to_hash {
   my %manifest;
   open my $M, '<:raw', 'MANIFEST'  or _error "Can not open file(MANIFEST): $!";
   while ( my $line = readline $M ) {
      chomp $line;
      my($file, undef) = split m{\s+}xms, $line;
      $manifest{$file} = 1;
   }
   close $M or _error "Unable to close FH: $!";
   return %manifest;
}

sub build {
    _chdir( $path{build} );
    my ( $build_pl, $makefile_pl ) = ( 0, 0 );

    if (   ! -e 'Build.PL'
        && ! -e 'Makefile.PL'
        &&   -e 'SPEC'
        &&   -e catfile(qw( builder lib Build.pm ))
    ) {
        # This looks like "my" thing, but missing a builder
        _print "[DEBUG] CREATING Build.PL from SPEC as no builder is present.\n";
        unshift @INC, catdir $path{build}, qw( builder lib );
        require Build;
        Build->_add_automatic_build_pl;
    }

    if ( -e 'Build.PL' && !$O{nomb} ) {
        call("$PERL_EXE Build.PL");
        call("$PERL_EXE Build");
        call("$PERL_EXE Build extratest");
        call("$PERL_EXE Build dist");
        call("$PERL_EXE Build disttest");
        call("$PERL_EXE Build clean");
        $build_pl++;
    }
    else {
        _print tts( L('build.buildpl'), [ target => $target ] );
    }

    if ( -e 'Makefile.PL' && ! $O{nomm} ) {
        call( "$PERL_EXE Makefile.PL");
        call( $MAKE );
        call( $MAKE . ' test' );
        if ( ! $build_pl && $ALIEN ) {
            call( $MAKE . ' dist'     );
            call( $MAKE . ' disttest' );
        }
        $makefile_pl++;
    }
    else {
        _print tts( L('build.makefilepl'), [ target => $target ] ) if !$O{nomm};
    }

    _error tts( L('build.nobuilder'), [ target => $target ] )
        if !$build_pl && !$makefile_pl;

    if ( $O{install} && $build_pl ) {
        my $sudo = $O{sudo} ? q(sudo ) : q();
        call("$PERL_EXE Build");
        call("${sudo}$PERL_EXE Build install");
    }
    return;
}

sub ask {
    my @modlist;
    opendir my $MODDIR, $path{source}
      or _error "$path{source} dizini okunamıyor: $!";

    while ( my $file = readdir $MODDIR ) {
        next if $file =~ m{ \A [._] }xms;
        next if !-d catdir( $path{source}, $file );
        if (
               ! -e catdir( $path{source}, $file, 'Build.PL' )
            && ! -e catdir( $path{source}, $file, 'Makefile.PL' )
            && ! -e catdir( $path{source}, $file, 'SPEC' )
        ){
            _print tts( L('ask.nobuilder'), [ path => $file ] );
            next;
        }
        push @modlist, $file;
    }
    closedir $MODDIR;

    _error L('ask.nomodules') if ! @modlist;

    @modlist = sort { lc $a cmp lc $b } @modlist;

    _print L('ask.found');
    foreach my $i ( 0 .. $#modlist ) {
        printf "   [% 2s] %s\n", $i + 1, $modlist[$i];
    }

    _print "\n";

    my $in = $O{module};

    my( $targetx, $modnamex );
    ASK: {
        _print L('ask.selection');
        chomp( $targetx = $in ? $in : <STDIN> );
        $in = undef;

        $targetx = 1 if not $targetx;

        if ( $targetx eq 'exit' || $targetx eq 'q' ) {
            _print( L('exit.message') );
            exit;
        };

        if ( $targetx =~ m/[^0-9]/xms ) { ## no critic (ProhibitEnumeratedClasses)
            _print( L('error.notnumber') );
            redo ASK;
        }

        if ( length($targetx) > MAX_MODNAME_LENGTH ) {
            _print( L('error.length') );
            redo ASK;
        }

        if ( ! exists $modlist[ $targetx - 1 ] ) {
            _print( L('error.notexists') );
            redo ASK;
        }

        $targetx = $modlist[ $targetx - 1 ];
        ( $modnamex = $targetx ) =~ s{[-]}{::}xmsg;
    }

    _print tts( L('ask.ok'), [ target => $targetx, modname => $modnamex ] );
    return $targetx, $modnamex;
}

sub hello {
    my $old = delete $SIG{__WARN__}; # local() does not seem to work. string eval?
    # disable unknown system warnings
    $SIG{__WARN__} = sub {1}; ## no critic (RequireLocalizedPunctuationVars)
    return if ! eval {
        require Sys::Info;
        1;
    };

    my($info, $os, %meta);
    SYSINFO: {
        $info = Sys::Info->new;
        $os   = $info->os;
        %meta = $os->meta;
    }

    _print tts( L('hello.hello'), [
        os   => $os->name(qw/ long 1 edition 1 /),
        perl => $info->perl_long,
        cpu  => scalar $info->device('CPU')->identify,
        ram  => sprintf( L('hello.ram'), $meta{'physical_memory_total'} / RAMGB ),
    ] );
    $SIG{__WARN__} = $old; ## no critic (RequireLocalizedPunctuationVars)
    return;
}

sub _chdir {
    my $dir = shift || _error L('_chdir.noparam');
    chdir $dir or _error tts( L('_chdir.error'), [ dir => $dir, error => $! ] );
    return;
}

sub copy_dist {
    find sub {
        if ( / tar[.]gz \z/xms ) {
            my $dist = catfile( $path{archive}, $_ );
            _print "[DEBUG] copy $_, $dist\n";
            copy $_, $dist;
        }
    }, $path{build};
    return;
}

sub call {
    my @cmd = @_;
    _print "[DEBUG] @cmd\n";
    system(@cmd) && do {
        finish();
        _error tts( L('call.error'), [ cmd => "@cmd", error => $? ] );
    };
    return;
}

sub write_file {
    my($mode, $file, @data) = @_;
    $mode = $mode . ':raw';
    open my $FH, $mode, $file
        or _error tts( L('write_file.error'), [ file => $file, error => $! ] );
    print {$FH} @data or _error "Unable to print to FH: $!";
    close $FH or _error "Unable to close FH: $!";
    return;
}

sub unix {
    my $f = shift or _error L('unix.nofile');

    open my $ORIGINAL, '<:raw', $f
        or _error tts( L('unix.eread'),  [ file => $f, error => $! ] );
    open my $NEWFILE,  '>:raw', $f . '.foo'
        or _error tts( L('unix.ewrite'), [ file => $f, error => $! ] );

    _unix_clean( $ORIGINAL, $NEWFILE );

    close $ORIGINAL or _error "Unable to close FH: $!";
    close $NEWFILE  or _error "Unable to close FH: $!";

    unlink $f;
    rename $f . '.foo', $f;

    return;
}

sub _unix_clean {
    my($original_fh, $new_fh) = @_;
    while (<$original_fh>) {
        s/\r\n/\n/xms;
        print {$new_fh} $_ or _error "Unable to print to FH: $!";;
    }
    return;
}

sub load_lang {
    my $lang = defined &LANG_ID       ? LANG_ID()
             : $ENV{BURAK_BUILD_LANG} ? $ENV{BURAK_BUILD_LANG}
             :                          'en';

    my $lang_dir = catdir( BASE_DIR, 'lang' );
    opendir my $DIR, $lang_dir or die "Can't read base dir: $!";
    my %valid;
    while ( my $dir = readdir $DIR ) {
        next if $dir =~ m{ \A [.] }xms || ! -d catdir( $lang_dir, $dir );
        $valid{ $dir } = 1;
    }
    closedir $DIR;

    $lang = lc $lang;
    if ( ! $valid{ $lang } ) {
        warn "'$lang' is not a valid language in identifier. 'en' will be used.";
        $lang = 'en';
    }

    my $file = catfile( BASE_DIR, 'lang', $lang, 'build.lng' );
    my %lang;
    my $raw = slurp $file;
    eval $raw;
    die "Can't load language file $file: $!" if $@;
    die "%lang hash is empty (loaded from $file)" if ! %lang;

    return \%lang, $lang;
}

1;

__END__
