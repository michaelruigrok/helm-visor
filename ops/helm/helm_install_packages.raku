#!/usr/bin/env rakudo
#
# Installs helm packages defined in a pkg JSON file
#
# This file has been over-commented, to assist those new to Raku.
# Please ensure any comments are up-to-date when you edit code.

use JSON::Fast;

# eg @var[?]. Turn a possible Nil into an empty list []
sub postfix:<[?]>(Any $var) { $var // [] }

# converts...
# "a" : {
#   "b": 1,
#   "c": 2,
#   }
# }
# to
# {
#   "a.b": 1,
#   "a.c": 2
# }
# for all nested objects
sub helmSetPairs(%map) {
	%map.map( -> $parent {
		given $parent.value {
			# merge any child structures into the current one, combining keys into a single key
			when Map { $_.&helmSetPairs.map(-> $child { "{$parent.key}.{$child.key}"  => $child.value }).Slip }
			when Seq { $_.&helmSetPairs.map(-> $child { "{$parent.key}[{$child.key}]" => $child.value }).Slip }
			default  { $parent.key => $parent.value }
		}
	});
}

sub MAIN(
	Bool :$diff,
	Bool :$dry-run,
	*@files where { $_ > 0 && $_.all.IO.f },
) {
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
		my Str $setArgs = .<set>[?].&helmSetPairs.map({" --set {.key}={.value}"}).join;
		my Str $versionArgs = .<version> ?? " --version {.<version>}" !! '';

		my $task = Proc::Async.new(<<
			echo helm {'diff' if $diff}
				upgrade --install "$_.<name>" "$_.<chart>"
				--repo "{.<repo> // ""}
				--namespace "$_.<namespace>"
				{ '--create-namespace' if not $diff }
				{'--dry-run' if $dry-run}
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
