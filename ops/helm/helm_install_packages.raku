#!/usr/bin/env rakudo
#
# Installs helm packages defined in a pkg JSON file
#
# This file has been over-commented, to assist those new to Raku.
# Please ensure any comments are up-to-date when you edit code.

use JSON::Fast;

# eg @var[?]. Turn a possible Nil into an empty list []
sub postfix:<[?]>(Any $var) { $var // [] }

sub MAIN(*@files where { $_ > 0 && $_.all.IO.f }) {
	my @packages = @files.map( -> $file {
		$file.IO.slurp.&from-json # get json array of packages from file
			# add file as a field to each package
			# '$_' is a 'topic variable', the default var name for a lambda/closure
			.map({ $_.append('file', $file) })
			.Slip; # merge into a single list
	});

	for @packages { .<chart> //= .<name> } # default 'chart' field to value of 'name' if not set

	# hashmap of {name => package}, for easy lookup
	my %packages = @packages.map({ $_.<name> => $_ });

	# test for loops in the dependency chain
	sub checkDependencies(@depChain) {
		my $last = @depChain[*-1];
		for %packages{$last}<dependencies>[?] {
			if ! %packages{$_} { die "Dependency $_ is not defined in this file!" }
			if $_ (elem) @depChain { die "Dependency $_ contains circular loop: {@depChain}" }
			checkDependencies([|@depChain, $_]);
		}
	}
	for @packages { checkDependencies([.<name>]) }

	# %done records a 'promise' for each package, so it wait for dependencies to be installed
	my %done;
	for %packages.values { %done{.<name>} = Promise.new() }

	# hyper splits each element to run on its own thread, asyncronously.
	for @packages.hyper { 
		for .<dependencies>[?].map({ %packages{$_} }) {
			await %done{.<name>};
			with .<waitCommand> { .&shell or fail } 
		}

		for @(.<pre-hook>[?]) { .&shell or fail }

		my Str $valArgs = .<values>[?].map(-> $valueFile {" --values {.<file>.IO.dirname}/$valueFile"}).join;
		my Str $setArgs = .<set>[?].map({" --set {.key}={.value}"}).join;
		my Str $versionArgs = .<version> ?? " --version {.<version>}" !! '';

		my $task = Proc::Async.new(<<
			helm upgrade --install "$_.<name>" "$_.<chart>" --repo "{.<repo> // ""}"
				--namespace "$_.<namespace>" --create-namespace
				$valArgs $setArgs $versionArgs
			>>);

		with .<name> -> $name {
			$task.start.then({ %done{$name}.keep });
		}
	}

	await %done.values;
	for @packages {
		with .<waitCommand> { .&shell || fail }
	}
}
