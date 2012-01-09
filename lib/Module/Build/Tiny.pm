package Module::Build::Tiny;
use strict;
use warnings;
use Exporter 5.57 'import';
our @EXPORT = qw/Build Build_PL/;

use CPAN::Meta;
use ExtUtils::BuildRC 0.003 qw/read_config/;
use ExtUtils::Config 0.003;
use ExtUtils::Helpers 0.010 qw/make_executable split_like_shell man1_pagename man3_pagename/;
use ExtUtils::Install qw/pm_to_blib install/;
use ExtUtils::InstallPaths 0.002;
use File::Basename qw/dirname/;
use File::Find::Rule qw/find/;
use File::Path qw/mkpath/;
use File::Slurp qw/read_file write_file/;
use File::Spec::Functions qw/catfile catdir rel2abs/;
use Getopt::Long qw/GetOptions/;
use JSON 2 qw/encode_json decode_json/;
use TAP::Harness;

sub _get_meta {
	my ($metafile) = grep { -e $_ } qw/META.json META.yml/ or die "No META information provided\n";
	return CPAN::Meta->load_file($metafile);
}

sub _manify {
	my ($input_file, $output_file, $section, $opts) = @_;
	my $dirname = dirname($output_file);
	mkpath($dirname, $opts->{verbose}) if not -d $dirname;
	Pod::Man->new(section => $section)->parse_from_file($input_file, $output_file);
	print "Manifying $output_file\n" if $opts->{verbose} && $opts->{verbose} > 0;
	return;
}

my %actions = (
	build => sub {
		my %opt = @_;
		system $^X, $_ and die "$_ returned $?\n" for find(file => name => '*.PL', in => 'lib');
		my %modules = map { $_ => catfile('blib', $_) } find(file => name => [qw/*.pm *.pod/], in => 'lib');
		my %scripts = map { $_ => catfile('blib', $_) } find(file => name => '*', in => 'script');
		pm_to_blib({ %modules, %scripts }, catdir(qw/blib lib auto/));
		make_executable($_) for values %scripts;

		if ($opt{install_paths}->is_default_installable('libdoc')) {
			_manify($_, catfile('blib', 'bindoc', man1_pagename($_)), 1, \%opt) for keys %scripts;
			_manify($_, catfile('blib', 'libdoc', man3_pagename($_)), 3, \%opt) for keys %modules;
		}
	},
	test => sub {
		my %opt = @_;
		die "Must run `./Build build` first\n" if not -d 'blib';
		my $tester = TAP::Harness->new({verbosity => $opt{verbose}, lib => rel2abs(catdir(qw/blib lib/)), color => -t STDOUT});
		$tester->runtests(sort +find(file => name => '*.t', in => 't'))->has_errors and exit 1;
	},
	install => sub {
		my %opt = @_;
		die "Must run `./Build build` first\n" if not -d 'blib';
		install($opt{install_paths}->install_map, @opt{qw/verbose dry_run uninst/});
	},
);

sub Build {
	my $bpl = decode_json(read_file('_build_params'));
	my $action = @ARGV && $ARGV[0] =~ /\A\w+\z/ ? shift @ARGV : 'build';
	die "No such action '$action'\n" if not $actions{$action};
	my $rc_opts = read_config();
	my @env = defined $ENV{PERL_MB_OPT} ? split_like_shell($ENV{PERL_MB_OPT}) : ();
	unshift @ARGV, map { @{$_} } grep { defined } $rc_opts->{'*'}, $bpl, $rc_opts->{$action}, \@env;
	GetOptions(\my %opt, qw/install_base=s install_path=s% installdirs=s destdir=s prefix=s config=s% uninst:1 verbose:1 dry_run:1/);
	@opt{'config', 'meta'} = (ExtUtils::Config->new($opt{config}), _get_meta());
	$actions{$action}->(%opt, install_paths => ExtUtils::InstallPaths->new(%opt, dist_name => $opt{meta}->name));
}

sub Build_PL {
	my $meta = _get_meta();
	printf "Creating new 'Build' script for '%s' version '%s'\n", $meta->name, $meta->version;
	my $dir = $meta->name eq 'Module-Build-Tiny' ? 'lib' : 'inc';
	write_file('Build', "#!perl\nuse lib '$dir';\nuse Module::Build::Tiny;\nBuild();\n");
	make_executable('Build');
	write_file(qw/_build_params/, encode_json(\@ARGV));
	write_file("MY$_", read_file($_)) for grep { -f } qw/META.json META.yml/;
}

1;

__END__

#ABSTRACT: A tiny replacement for Module::Build

=head1 SYNOPSIS

 use Module::Build::Tiny;
 BuildPL();

=head1 DESCRIPTION

Many Perl distributions use a Build.PL file instead of a Makefile.PL file
to drive distribution configuration, build, test and installation.
Traditionally, Build.PL uses Module::Build as the underlying build system.
This module provides a simple, lightweight, drop-in replacement.

Whereas Module::Build has over 6,700 lines of code; this module has less
than 70, yet supports the features needed by most pure-Perl distributions.

=head2 Supported

=over 4

=item * Pure Perl distributions

=item * Recursive test files

=item * MYMETA

=item * Man page generation

=item * Generated code from PL files

=back

=head2 Not Supported

=over 4

=item * Dynamic prerequisites

=item * Building XS or C

=item * HTML documentation generation

=item * Extending Module::Build::Tiny

=back

=head2 Directory structure

Your .pm and .pod files must be in F<lib/>.  Any executables must be in
F<script/>.  Test files must be in F<t/>.


=head1 USAGE

These all work pretty much like their Module::Build equivalents.

=head2 perl Build.PL

=head2 Build [ build ] 

=head2 Build test

=head2 Build install

This supports the following options:

=over

=item * install_base

=item * installdirs

=item * prefix

=item * install_path

=item * destdir

=item * uninst

=back

=head1 AUTHORING

This module doesn't support authoring. To develop modules using Module::Build::Tiny, usage of L<Dist::Zilla::Plugin::ModuleBuildTiny> is recommended.

=head1 CONFIG FILE AND ENVIRONMENT

Options can be provided in a F<.modulebuildrc> file or in the C<PERL_MB_OPT>
environment variable the same way they can with Module::Build.

=head1 SEE ALSO

L<Module::Build>

=for Pod::Coverage
Build_PL
=end

=cut

# vi:et:sts=2:sw=2:ts=2
