# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

use strict;
use warnings;

package Clownfish::CFC::Perl::Build;
use base qw( Module::Build );
our $VERSION = '0.004000';
$VERSION = eval $VERSION;

use File::Spec::Functions qw( catdir catfile curdir updir abs2rel rel2abs );
use File::Path qw( mkpath );
use Config;
use Carp;

# Add a custom Module::Build hashref property to pass additional build
# parameters
if ( $Module::Build::VERSION <= 0.30 ) {
    __PACKAGE__->add_property( clownfish_params => {} );
}
else {
    # TODO: add sub for property check
    __PACKAGE__->add_property(
        'clownfish_params',
        default => {},
    );
}

# Rationale

# When the distribution tarball for the Perl bindings is built, core/, and any
# other needed files/directories are copied into the perl/ directory within the
# main source directory.  Then the distro is built from the contents of the
# perl/ directory, leaving out all the files in ruby/, etc. However, during
# development, the files are accessed from their original locations.

my @BASE_PATH;
push(@BASE_PATH, updir()) unless -e 'core';

my $AUTOGEN_DIR  = 'autogen';
my $LIB_DIR      = 'lib';
my $BUILDLIB_DIR = 'buildlib';

sub new {
    my $self = shift->SUPER::new( @_ );

    # TODO: use Charmonizer to determine whether pthreads are userland.
    if ( $Config{osname} =~ /openbsd/i && $Config{usethreads} ) {
        my $extra_ldflags = $self->extra_linker_flags;
        push @$extra_ldflags, '-lpthread';
        $self->extra_linker_flags(@$extra_ldflags);
    }

    my $cf_source = $self->clownfish_params('source');
    if ( !defined($cf_source) ) {
        $cf_source = [];
    }
    elsif ( !ref($cf_source) ) {
        $cf_source = [ $cf_source ];
    }
    push( @$cf_source, catdir( $AUTOGEN_DIR, 'source' ) );
    $self->clownfish_params( source => $cf_source );

    my $cf_include = $self->clownfish_params('include') || [];
    # Add include dirs from CLOWNFISH_INCLUDE environment variable.
    if ($ENV{CLOWNFISH_INCLUDE}) {
        push( @$cf_include, split( /:/, $ENV{CLOWNFISH_INCLUDE} ) );
    }
    # Add include dirs from @INC.
    for my $dir (@INC) {
        my $cf_incdir = catdir( $dir, 'Clownfish', '_include' );
        push( @$cf_include, $cf_incdir ) if -d $cf_incdir;
    }
    $self->clownfish_params( include => $cf_include );

    my $include_dirs = $self->include_dirs;
    push( @$include_dirs,
        curdir(), # for ppport.h
        catdir( $AUTOGEN_DIR, 'include' ),
        @$cf_include,
    );
    $self->include_dirs($include_dirs);

    my $autogen_header = $self->clownfish_params('autogen_header');
    if ( !defined($autogen_header) ) {
        $self->clownfish_params( autogen_header => <<'END_AUTOGEN' );
/***********************************************

 !!!! DO NOT EDIT !!!!

 This file was auto-generated by Build.PL.

 ***********************************************/

END_AUTOGEN
    }

    return $self;
}

sub cf_base_path {
    my $self_or_class = shift;
    return @BASE_PATH;
}

sub cf_linker_flags {
    my $self_or_class = shift;

    my $dlext = $Config{dlext};
    # Only needed on Windows
    return () if $dlext ne 'dll';

    # Link against import library on MSVC
    my $ext = $Config{cc} =~ /^cl\b/ ? 'lib' : $dlext;

    my @linker_flags;

    for my $module_name (@_) {
        # Find library to link against
        my @module_parts = split( '::', $module_name );
        my $class_name   = $module_parts[-1];
        my $lib_file;
        my $found;

        for my $dir (@INC) {
            $lib_file = catfile(
                $dir, 'auto', @module_parts, "$class_name.$ext",
            );
            if ( -f $lib_file ) {
                $found = 1;
                last;
            }
        }

        die("No Clownfish library file found for module $module_name")
            if !$found;

        push( @linker_flags, $lib_file );
    }

    return @linker_flags;
}

sub _cfh_filepaths {
    my $self = shift;
    my @paths;
    my $source_dirs = $self->clownfish_params('source');
    for my $source_dir (@$source_dirs) {
        next unless -e $source_dir;
        push @paths, @{ $self->rscan_dir( $source_dir, qr/\.cfh$/ ) };
    }
    return \@paths;
}

sub cf_copy_include_file {
    my ($self, @path) = @_;

    my $dest_dir     = catdir( $self->blib, 'arch', 'Clownfish', '_include' );
    my $include_dirs = $self->include_dirs;
    for my $include_dir (@$include_dirs) {
        my $file = catfile ( $include_dir, @path );
        if ( -e $file ) {
            $self->copy_if_modified(
                from => $file,
                to   => catfile( $dest_dir, @path ),
            );
            return;
        }
    }
    die( "Clownfish include file " . catfile(@path) . " not found" );
}

sub ACTION_copy_clownfish_includes {
    my $self = shift;

    # Copy .cfh files to blib/arch/Clownfish/_include
    my $inc_dir     = catdir( $self->blib, 'arch', 'Clownfish', '_include' );
    my $source_dirs = $self->clownfish_params('source');

    for my $source_dir (@$source_dirs) {
        my $cfh_filepaths = $self->rscan_dir( $source_dir, qr/\.cf[hp]$/ );

        for my $file (@$cfh_filepaths) {
            my $rel  = abs2rel( $file, $source_dir );
            my $dest = catfile( $inc_dir, $rel );
            $self->copy_if_modified( from => $file, to => $dest );
        }
    }
}

sub _compile_clownfish {
    my $self = shift;

    require Clownfish::CFC::Model::Hierarchy;
    require Clownfish::CFC::Binding::Perl;
    require Clownfish::CFC::Binding::Perl::Class;

    # Compile Clownfish.
    my $hierarchy = Clownfish::CFC::Model::Hierarchy->new(
        dest => $AUTOGEN_DIR,
    );
    my $source_dirs  = $self->clownfish_params('source');
    my $include_dirs = $self->clownfish_params('include');
    for my $source_dir (@$source_dirs) {
        $hierarchy->add_source_dir($source_dir);
    }
    for my $include_dir (@$include_dirs) {
        $hierarchy->add_include_dir($include_dir);
    }
    $hierarchy->build;

    # Process all Binding classes in buildlib.
    my $pm_filepaths = $self->rscan_dir( $BUILDLIB_DIR, qr/\.pm$/ );
    for my $pm_filepath (@$pm_filepaths) {
        next unless $pm_filepath =~ /Binding/;
        require $pm_filepath;
        my $package_name = $pm_filepath;
        $package_name =~ s/buildlib\/(.*)\.pm$/$1/;
        $package_name =~ s/\//::/g;
        $package_name->bind_all($hierarchy);
    }

    my $binding = Clownfish::CFC::Binding::Perl->new(
        hierarchy  => $hierarchy,
        lib_dir    => $LIB_DIR,
        boot_class => $self->module_name,
        header     => $self->clownfish_params('autogen_header'),
        footer     => '',
    );

    return ( $hierarchy, $binding );
}

sub ACTION_pod {
    my $self = shift;
    $self->depends_on('clownfish');
    $self->_write_pod(@_);
}

sub _write_pod {
    my ( $self, $binding ) = @_;
    if ( !$binding ) {
        ( undef, $binding ) = $self->_compile_clownfish;
    }
    print "Writing POD...\n";
    my $pod_files = $binding->write_pod;
    $self->add_to_cleanup($_) for @$pod_files;
}

sub ACTION_clownfish {
    my $self = shift;

    $self->add_to_cleanup($AUTOGEN_DIR);

    my @module_dir  = split( '::', $self->module_name );
    my $class_name  = pop(@module_dir);
    my $xs_filepath = catfile( $LIB_DIR, @module_dir, "$class_name.xs" );

    my $buildlib_pm_filepaths = $self->rscan_dir( $BUILDLIB_DIR, qr/\.pm$/ );
    my $cfh_filepaths = $self->_cfh_filepaths;

    # XXX joes thinks this is dubious
    # Don't bother parsing Clownfish files if everything's up to date.
    return
        if $self->up_to_date(
        [ @$cfh_filepaths, @$buildlib_pm_filepaths ],
        [ $xs_filepath,    $AUTOGEN_DIR, ]
        );

    # Write out all autogenerated files.
    print "Parsing Clownfish files...\n";
    my ( $hierarchy, $perl_binding ) = $self->_compile_clownfish;
    require Clownfish::CFC::Binding::Core;
    my $core_binding = Clownfish::CFC::Binding::Core->new(
        hierarchy => $hierarchy,
        header    => $self->clownfish_params('autogen_header'),
        footer    => '',
    );
    print "Writing Clownfish autogenerated files...\n";
    my $modified = $core_binding->write_all_modified;
    if ($modified) {
        unlink('typemap');
        print "Writing typemap...\n";
        $self->add_to_cleanup('typemap');
        $perl_binding->write_xs_typemap;
    }

    # Rewrite XS if either any .cfh files or relevant .pm files were modified.
    $modified ||=
        $self->up_to_date( \@$buildlib_pm_filepaths, $xs_filepath )
        ? 0
        : 1;

    if ($modified) {
        $self->add_to_cleanup($xs_filepath);
        $perl_binding->write_callbacks;
        $perl_binding->write_boot;
        $perl_binding->write_hostdefs;
        $perl_binding->write_bindings;
        $self->_write_pod($perl_binding);
    }

    # Touch autogenerated files in case the modifications were inconsequential
    # and didn't trigger a rewrite, so that we won't have to check them again
    # next pass.
    if (!$self->up_to_date(
            [ @$cfh_filepaths, @$buildlib_pm_filepaths ], $xs_filepath
        )
        )
    {
        utime( time, time, $xs_filepath );    # touch
    }
    if (!$self->up_to_date(
            [ @$cfh_filepaths, @$buildlib_pm_filepaths ], $AUTOGEN_DIR
        )
        )
    {
        utime( time, time, $AUTOGEN_DIR );    # touch
    }
}

# Write ppport.h, which supplies some XS routines not found in older Perls and
# allows us to use more up-to-date XS API while still supporting Perls back to
# 5.8.3.
#
# The Devel::PPPort docs recommend that we distribute ppport.h rather than
# require Devel::PPPort itself, but ppport.h isn't compatible with the Apache
# license.
sub ACTION_ppport {
    my $self = shift;
    if ( !-e 'ppport.h' ) {
        require Devel::PPPort;
        $self->add_to_cleanup('ppport.h');
        Devel::PPPort::WriteFile();
    }
}

sub ACTION_compile_custom_xs {
    my $self = shift;

    $self->depends_on('ppport');

    require ExtUtils::CBuilder;
    require ExtUtils::ParseXS;

    my $module_name  = $self->module_name;
    my @module_parts = split( '::', $module_name );
    my @module_dir   = @module_parts;
    my $class_name   = pop(@module_dir);

    my $cbuilder = ExtUtils::CBuilder->new( config => $self->config );
    my $libdir   = catdir( $LIB_DIR, @module_dir );
    my $archdir  = catdir( $self->blib, 'arch', 'auto', @module_parts );
    mkpath( $archdir, 0, 0777 ) unless -d $archdir;
    my @objects;

    # Compile C source files.
    my $c_files = [];
    my $source_dirs = $self->clownfish_params('source');
    for my $source_dir (@$source_dirs) {
        push @$c_files, @{ $self->rscan_dir( $source_dir, qr/\.c$/ ) };
    }
    my $extra_cflags = $self->clownfish_params('cflags');
    for my $c_file (@$c_files) {
        my $o_file   = $c_file;
        my $ccs_file = $c_file;
        $o_file   =~ s/\.c$/$Config{_o}/ or die "no match";
        $ccs_file =~ s/\.c$/.ccs/        or die "no match";
        push @objects, $o_file;
        next if $self->up_to_date( $c_file, $o_file );
        $self->add_to_cleanup($o_file);
        $self->add_to_cleanup($ccs_file);
        $cbuilder->compile(
            source               => $c_file,
            extra_compiler_flags => $extra_cflags,
            include_dirs         => $self->include_dirs,
            object_file          => $o_file,
        );
    }

    # .xs => .c
    my $xs_filepath         = catfile( $libdir, "$class_name.xs" );
    my $perl_binding_c_file = catfile( $libdir, "$class_name.c" );
    $self->add_to_cleanup($perl_binding_c_file);
    if ( !$self->up_to_date( $xs_filepath, $perl_binding_c_file ) ) {
        ExtUtils::ParseXS::process_file(
            filename   => $xs_filepath,
            prototypes => 0,
            output     => $perl_binding_c_file,
        );
    }

    # .c => .o
    my $version = $self->dist_version;
    my $perl_binding_o_file = catfile( $libdir, "$class_name$Config{_o}" );
    unshift @objects, $perl_binding_o_file;
    $self->add_to_cleanup($perl_binding_o_file);
    if ( !$self->up_to_date( $perl_binding_c_file, $perl_binding_o_file ) ) {
        # Don't use Clownfish compiler flags for XS
        $cbuilder->compile(
            source               => $perl_binding_c_file,
            extra_compiler_flags => $self->extra_compiler_flags,
            include_dirs         => $self->include_dirs,
            object_file          => $perl_binding_o_file,
            # 'defines' is an undocumented parameter to compile(), so we
            # should officially roll our own variant and generate compiler
            # flags.  However, that involves writing a bunch of
            # platform-dependent code, so we'll just take the chance that this
            # will break.
            defines => {
                VERSION    => qq|"$version"|,
                XS_VERSION => qq|"$version"|,
            },
        );
    }

    # Create .bs bootstrap file, needed by Dynaloader.
    my $bs_file = catfile( $archdir, "$class_name.bs" );
    $self->add_to_cleanup($bs_file);
    if ( !$self->up_to_date( $perl_binding_o_file, $bs_file ) ) {
        require ExtUtils::Mkbootstrap;
        ExtUtils::Mkbootstrap::Mkbootstrap($bs_file);
        if ( !-f $bs_file ) {
            # Create file in case Mkbootstrap didn't do anything.
            open( my $fh, '>', $bs_file )
                or confess "Can't open $bs_file: $!";
        }
        utime( (time) x 2, $bs_file );    # touch
    }

    # Clean up after CBuilder under MSVC.
    $self->add_to_cleanup('compilet*');
    $self->add_to_cleanup('*.ccs');
    $self->add_to_cleanup( catfile( $libdir, "$class_name.ccs" ) );
    $self->add_to_cleanup( catfile( $libdir, "$class_name.def" ) );
    $self->add_to_cleanup( catfile( $libdir, "${class_name}_def.old" ) );
    $self->add_to_cleanup( catfile( $libdir, "$class_name.exp" ) );
    $self->add_to_cleanup( catfile( $libdir, "$class_name.lib" ) );
    $self->add_to_cleanup( catfile( $libdir, "$class_name.lds" ) );
    $self->add_to_cleanup( catfile( $libdir, "$class_name.base" ) );

    # .o => .(a|bundle)
    my $lib_file = catfile( $archdir, "$class_name.$Config{dlext}" );
    if ( !$self->up_to_date( [ @objects, $AUTOGEN_DIR ], $lib_file ) ) {
        $cbuilder->link(
            module_name        => $module_name,
            objects            => \@objects,
            lib_file           => $lib_file,
            extra_linker_flags => $self->extra_linker_flags,
        );
        # Install .lib file on Windows
        my $implib_file = catfile( $libdir, "$class_name.lib" );
        if ( -e $implib_file ) {
            $self->copy_if_modified(
                from => $implib_file,
                to   => catfile( $archdir, "$class_name.lib" ),
            );
        }
    }
}

sub ACTION_code {
    my $self = shift;

    $self->depends_on(qw(
        clownfish
        compile_custom_xs
        copy_clownfish_includes
    ));

    $self->SUPER::ACTION_code;
}

# Monkey patch ExtUtils::CBuilder::Platform::Windows::GCC::format_linker_cmd
# to make extensions work on MinGW.
#
# nwellnhof: The original ExtUtils::CBuilder implementation uses dlltool and a
# strange incremental linking scheme. I think this is only needed for ancient
# versions of GNU ld. It somehow breaks exporting of symbols via
# __declspec(dllexport). Starting with version 2.17, one can pass .def files
# to GNU ld directly, which requires only a single command and gets the
# exports right.
{
    no warnings 'redefine';
    require ExtUtils::CBuilder::Platform::Windows::GCC;
    *ExtUtils::CBuilder::Platform::Windows::GCC::format_linker_cmd = sub {
      my ($self, %spec) = @_;
      my $cf = $self->{config};

      # The Config.pm variable 'libperl' is hardcoded to the full name
      # of the perl import library (i.e. 'libperl56.a'). GCC will not
      # find it unless the 'lib' prefix & the extension are stripped.
      $spec{libperl} =~ s/^(?:lib)?([^.]+).*$/-l$1/;

      unshift( @{$spec{other_ldflags}}, '-nostartfiles' )
        if ( $spec{startup} && @{$spec{startup}} );

      # From ExtUtils::MM_Win32:
      #
      ## one thing for GCC/Mingw32:
      ## we try to overcome non-relocateable-DLL problems by generating
      ##    a (hopefully unique) image-base from the dll's name
      ## -- BKS, 10-19-1999
      File::Basename::basename( $spec{output} ) =~ /(....)(.{0,4})/;
      $spec{image_base} = sprintf( "0x%x0000", unpack('n', $1 ^ $2) );

      %spec = $self->write_linker_script(%spec)
        if $spec{use_scripts};

      foreach my $path ( @{$spec{libpath}} ) {
        $path = "-L$path";
      }

      my @cmds; # Stores the series of commands needed to build the module.

      # split off any -arguments included in ld
      my @ld = split / (?=-)/, $spec{ld};

      push @cmds, [ grep {defined && length} (
        @ld                       ,
        '-o', $spec{output}       ,
        "-Wl,--image-base,$spec{image_base}" ,
        @{$spec{lddlflags}}       ,
        @{$spec{libpath}}         ,
        @{$spec{startup}}         ,
        @{$spec{objects}}         ,
        @{$spec{other_ldflags}}   ,
        $spec{libperl}            ,
        @{$spec{perllibs}}        ,
        $spec{def_file}           ,
        $spec{map_file} ? ('-Map', $spec{map_file}) : ''
      ) ];

      return @cmds;
    };
}

1;

__END__

=head1 NAME

Clownfish::CFC::Perl::Build - Build Clownfish modules.

=head1 DESCRIPTION

Clownfish::CFC::Perl::Build is a subclass of L<Module::Build> which builds
the Perl bindings for Clownfish modules.

=head1 SYNOPSIS

    use Clownfish::CFC::Perl::Build;
    use File::Spec::Functions qw( catdir );

    my @cf_base_path    = Clownfish::CFC::Perl::Build->cf_base_path;
    my @cf_linker_flags = Clownfish::CFC::Perl::Build->cf_linker_flags(
        'Other::Module',
    );

    my $builder = Clownfish::CFC::Perl::Build->new(
        module_name        => 'My::Module',
        dist_abstract      => 'Do something with this and that',
        dist_author        => 'The Author <author@example.com>',
        dist_version       => '0.1.0',
        extra_linker_flags => [ @cf_linker_flags ],
        clownfish_params => {
            source  => [ catdir( @cf_base_path, 'core' ) ],
        },
        requires => {
            'Other::Module' => '0.3.0',
        },
        configure_requires => {
            'Clownfish::CFC::Perl::Build' => 0.004000,
        },
        build_requires => {
            'Clownfish::CFC::Perl::Build' => 0.004000,
        },
    );

    $builder->create_build_script();

=head1 BUILD ACTIONS

Clownfish::CFC::Perl::Build defines the following build actions.

=head2 code

Build the whole project. The C<code> action searches the C<buildlib>
directory for .pm files whose path contains the string C<Binding>. For each
module found, the class method C<bind_all> will be called with a
L<Clownfish::CFC::Model::Hierarchy> object as argument. This method
should register all the L<Clownfish::CFC::Binding::Perl::Class> objects
for which bindings should be generated.

For example, the file C<buildlib/My/Module/Binding.pm> could look like:

    package My::Module::Binding;

    sub bind_all {
        my ($class, $hierarchy) = @_;

        my $binding = Clownfish::CFC::Binding::Perl::Class->new(
            parcel     => 'MyModule',
            class_name => 'My::Module::Class',
        );
        Clownfish::CFC::Binding::Perl::Class->register($binding);
    }

=head2 clownfish

Compile the Clownfish headers and generate code in the C<autogen> directory.

=head2 pod

Generate POD from Clownfish headers.

=head1 CONSTRUCTOR

=head2 new( I<[labeled params]> )

    my $builder = Clownfish::CFC::Perl::Build->new(%args);

Creates a new Clownfish::CFC::Perl::Build object. C<%args> can contain all
arguments that can be passed to L<Module::Build::API/new>. It accepts an
additional argument C<clownfish_params> which is a hashref with the following
params:

=over

=item *

B<source> - An arrayref of source directories containing the .cfh and .c files
of the module. Defaults to C<[ 'core' ]> or to C<[ '../core' ]> if C<core>
can't be found.

=item *

B<include> - An arrayref of include directories containing .cfh files from
other Clownfish modules needed by the module. Empty by default. Should contain
the Clownfish system include directories if needed.

=item *

B<autogen_header> - A string that will be prepended to the files generated by
the Clownfish compiler.

=item *

B<cflags> - A string with additional compiler flags used to compile the
Clownfish .c files.

=back

=head1 CLASS METHODS

=head2 cf_base_path()

    my @path = Clownfish::CFC::Perl::Build->cf_base_path();

Returns the base path components of the source tree where C<core> was found.
Currently either C<()> or C<('..')>.

=head2 cf_linker_flags( I<[module_names]> )

    my @flags = Clownfish::CFC::Perl::Build->cf_linker_flags(@module_names);

Returns the linker flags needed to link against all Clownfish modules in
C<@module_names>. Should be added to C<extra_linker_flags> for all module
dependencies. Only needed on Windows.

=head1 METHODS

=head2 cf_copy_include_file( I<[path components]> )

    $builder->cf_copy_include_file(@path);

Look for a file with path components C<@path> in all of the Module::Build
include dirs and copy it to C<blib>, so it will be installed in a Clownfish
system include directory. Typically used for additional .h files that the
.cfh files need.

=head2 clownfish_params()

    my $value = $builder->clownfish_params($key);

    $builder->clownfish_params($key => $value);

Get or set a Clownfish build param. Supports all the parameters that can be
passed to L</new>.

=cut

