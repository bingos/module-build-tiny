package Module::Build::Tiny;
use strict;
use warnings;
use Exporter 5.57 'import';
our @EXPORT = qw/Build Build_PL/;

use CPAN::Meta;
use ExtUtils::Config 0.003;
use ExtUtils::Helpers 0.020 qw/make_executable split_like_shell man1_pagename man3_pagename detildefy/;
use ExtUtils::Install qw/pm_to_blib install/;
use ExtUtils::InstallPaths 0.002;
use File::Basename qw/basename dirname/;
use File::Find ();
use File::Path qw/mkpath rmtree/;
use File::Spec::Functions qw/catfile catdir rel2abs abs2rel splitdir/;
use Getopt::Long qw/GetOptions/;
use JSON::PP 2 qw/encode_json decode_json/;

sub write_file {
	my ($filename, $mode, $content) = @_;
	open my $fh, ">:$mode", $filename or die "Could not open $filename: $!\n";;
	print $fh $content;
}
sub read_file {
	my ($filename, $mode) = @_;
	open my $fh, "<:$mode", $filename or die "Could not open $filename: $!\n";
	return do { local $/; <$fh> };
}

sub get_meta {
	my ($metafile) = grep { -e $_ } qw/META.json META.yml/ or die "No META information provided\n";
	return CPAN::Meta->load_file($metafile);
}

sub manify {
	my ($input_file, $output_file, $section, $opts) = @_;
	return if -e $output_file && -M $input_file <= -M $output_file;
	my $dirname = dirname($output_file);
	mkpath($dirname, $opts->{verbose}) if not -d $dirname;
	require Pod::Man;
	Pod::Man->new(section => $section)->parse_from_file($input_file, $output_file);
	print "Manifying $output_file\n" if $opts->{verbose} && $opts->{verbose} > 0;
	return;
}

sub process_xs {
	my ($source, $options) = @_;

	die "Can't build xs files under --pureperl-only\n" if $options->{'pureperl-only'};
	my (undef, @dirnames) = splitdir(dirname($source));
	my $file_base = basename($source, '.xs');
	my $archdir = catdir(qw/blib arch auto/, @dirnames, $file_base);

	my $c_file = catfile('lib', @dirnames, "$file_base.c");
	require ExtUtils::ParseXS;
	ExtUtils::ParseXS::process_file(filename => $source, prototypes => 0, output => $c_file);

	my $version = $options->{meta}->version;
	require ExtUtils::CBuilder;
	my $builder = ExtUtils::CBuilder->new(config => $options->{config}->values_set);
	my $ob_file = $builder->compile(source => $c_file, defines => { VERSION => qq/"$version"/, XS_VERSION => qq/"$version"/ });

	mkpath($archdir, $options->{verbose}, oct '755') unless -d $archdir;
	return $builder->link(objects => $ob_file, lib_file => catfile($archdir, "$file_base.".$options->{config}->get('dlext')), module_name => join '::', @dirnames, $file_base);
}

sub find {
	my ($pattern, $dir) = @_;
	my @ret;
	File::Find::find(sub { push @ret, $File::Find::name if /$pattern/ && -f }, $dir) if -d $dir;
	return @ret;
}

my %actions = (
	build => sub {
		my %opt = @_;
		system $^X, $_ and die "$_ returned $?\n" for find(qr/\.PL$/, 'lib');
		my %modules = map { $_ => catfile('blib', $_) } find(qr/\.p(?:m|od)$/, 'lib');
		my %scripts = map { $_ => catfile('blib', $_) } find(qr//, 'script');
		my %shared =  map { $_ => catfile(qw/blib lib auto share dist/, $opt{meta}->name, abs2rel($_, 'share')) } find(qr//, 'share');
		pm_to_blib({ %modules, %scripts, %shared }, catdir(qw/blib lib auto/));
		make_executable($_) for values %scripts;
		mkpath(catdir(qw/blib arch/), $opt{verbose});
		process_xs($_, \%opt) for find(qr/.xs$/, 'lib');

		if ($opt{install_paths}->install_destination('libdoc') && $opt{install_paths}->is_default_installable('libdoc')) {
			manify($_, catfile('blib', 'bindoc', man1_pagename($_)), $opt{config}->get('man1ext'), \%opt) for keys %scripts;
			manify($_, catfile('blib', 'libdoc', man3_pagename($_)), $opt{config}->get('man3ext'), \%opt) for keys %modules;
		}
	},
	test => sub {
		my %opt = @_;
		die "Must run `./Build build` first\n" if not -d 'blib';
		require TAP::Harness;
		my $tester = TAP::Harness->new({verbosity => $opt{verbose}, lib => [ map { rel2abs(catdir(qw/blib/, $_)) } qw/arch lib/ ], color => -t STDOUT});
		$tester->runtests(sort +find(qr/\.t$/, 't'))->has_errors and exit 1;
	},
	install => sub {
		my %opt = @_;
		die "Must run `./Build build` first\n" if not -d 'blib';
		install($opt{install_paths}->install_map, @opt{qw/verbose dry_run uninst/});
	},
	clean => sub {
		my %opt = @_;
		rmtree('blib', $opt{verbose});
	},
	realclean => sub {
		my %opt = @_;
		rmtree($_, $opt{verbose}) for qw/blib Build _build_params MYMETA.yml MYMETA.json/;
	},
);

sub Build {
	my $action = @ARGV && $ARGV[0] =~ /\A\w+\z/ ? shift @ARGV : 'build';
	die "No such action '$action'\n" if not $actions{$action};
	unshift @ARGV, @{ decode_json(read_file('_build_params', 'utf8')) };
	GetOptions(\my %opt, qw/install_base=s install_path=s% installdirs=s destdir=s prefix=s config=s% uninst:1 verbose:1 dry_run:1 pureperl-only:1 create_packlist=i/);
	$_ = detildefy($_) for grep { defined } @opt{qw/install_base destdir prefix/}, values %{ $opt{install_path} };
	@opt{'config', 'meta'} = (ExtUtils::Config->new($opt{config}), get_meta());
	$actions{$action}->(%opt, install_paths => ExtUtils::InstallPaths->new(%opt, dist_name => $opt{meta}->name));
}

sub Build_PL {
	my $meta = get_meta();
	printf "Creating new 'Build' script for '%s' version '%s'\n", $meta->name, $meta->version;
	my $dir = $meta->name eq 'Module-Build-Tiny' ? "use lib 'lib';" : '';
	write_file('Build', 'raw', "#!perl\n$dir\nuse Module::Build::Tiny;\nBuild();\n");
	make_executable('Build');
	my @env = defined $ENV{PERL_MB_OPT} ? split_like_shell($ENV{PERL_MB_OPT}) : ();
	write_file('_build_params', 'utf8', encode_json([ @env, @ARGV ]));
	$meta->save(@$_) for ['MYMETA.json'], ['MYMETA.yml' => { version => 1.4 }];
}

1;

#ABSTRACT: A tiny replacement for Module::Build

=head1 SYNOPSIS

 use Module::Build::Tiny;
 Build_PL();

=head1 DESCRIPTION

Many Perl distributions use a Build.PL file instead of a Makefile.PL file
to drive distribution configuration, build, test and installation.
Traditionally, Build.PL uses Module::Build as the underlying build system.
This module provides a simple, lightweight, drop-in replacement.

Whereas Module::Build has over 6,700 lines of code; this module has less
than 120, yet supports the features needed by most distributions.

=head2 Supported

=over 4

=item * Pure Perl distributions

=item * Building XS or C

=item * Recursive test files

=item * MYMETA

=item * Man page generation

=item * Generated code from PL files

=back

=head2 Not Supported

=over 4

=item * Dynamic prerequisites

=item * HTML documentation generation

=item * Extending Module::Build::Tiny

=item * Module sharedirs

=back

=head2 Directory structure

Your .pm and .pod files must be in F<lib/>.  Any executables must be in
F<script/>.  Test files must be in F<t/>. Dist sharedirs must be in F<share/>.


=head1 USAGE

These all work pretty much like their Module::Build equivalents.

=head2 perl Build.PL

=head2 Build [ build ] 

=head2 Build test

=head2 Build install

This supports the following options:

=over

=item * verbose

=item * install_base

=item * installdirs

=item * prefix

=item * install_path

=item * destdir

=item * uninst

=item * config

=item * pure-perl

=item * create_packlist

=back

=head1 AUTHORING

This module doesn't support authoring. To develop modules using Module::Build::Tiny, usage of L<Dist::Zilla::Plugin::ModuleBuildTiny> or L<App::ModuleBuildTiny> is recommended.

=head1 CONFIG FILE AND ENVIRONMENT

Options can be provided in the C<PERL_MB_OPT> environment variable the same way they can with Module::Build. This should be done during the configuration stage.

=head2 Incompatibilities

=over 4

=item * Argument parsing

Module::Build has an extremely permissive way of argument handling, Module::Build::Tiny only supports a (sane) subset of that. In particular, C<./Build destdir=/foo> does not work, you will need to pass it as C<./Build --destdir=/foo>.

=item * .modulebuildrc

Module::Build::Tiny does not support .modulebuildrc files. In particular, this means that versions of local::lib older than 1.006008 may break. Upgrading it resolves this issue.

=back

=head1 SEE ALSO

L<Module::Build>

=cut

# vi:et:sts=2:sw=2:ts=2
