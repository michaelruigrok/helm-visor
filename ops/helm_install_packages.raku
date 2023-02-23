#!/usr/bin/env rakudo
#
# Installs helm packages defined in a pkg JSON file

use JSON::Fast;

# eg @var[?]. Turn a possible Nil into an empty list []
sub postfix:<[?]>(Any $var) { $var // [] }

sub MAIN(*@files where { $_ > 0 && $_.all.IO.f }) {
	my @packages = @files.map({ $_.IO.slurp.&from-json }).flat;
	for @packages { .<chart> ||= .<name> }

	# convert to hashmap of {name: package}, for easier reference
	my %packages = @packages.map({ $_.<name> => $_ });

	# test for dependency loops
	sub checkDependencies(@depChain) {
		my $last = @depChain[*-1];
		for %packages{$last}<dependencies>[?] {
			if $_ (elem) @depChain { die "Dependency $_ contains circular loop: {@depChain}" }
			checkDependencies([|@depChain, $_]);
		}
	}
	for @packages { checkDependencies([.<name>]) }

	# done promises for each package to obey dependencies
	my %done;
	for %packages.values { %done{.<name>} = Promise.new() }

	for @packages.hyper { 
		for .<dependencies>[?].map({ %packages{$_} }) {
			await %done{.<name>};
			with .<waitCommand> { .&shell or fail } 
		}

		my Str $valArgs = .<values>[?].map({" --values $_"}).join;
		my Str $setArgs = .<set>[?].map({" --set {.key}={.value}"}).join;

		my $task = Proc::Async.new(<<
			helm upgrade --dry-run --install "$_.<name>" "$_.<chart>" --repo "{$_.<repo> // ""}"
				--namespace "$_.<namespace>" --create-namespace
				$valArgs $setArgs
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
