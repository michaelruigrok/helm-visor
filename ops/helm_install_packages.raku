#!/usr/bin/env rakudo
#
# Installs helm packages defined in a pkg JSON file

use JSON::Fast;

# eg @var[?]. Turn a possible Nil into an empty list []
sub postfix:<[?]>(Any $var) { $var // [] }

sub MAIN(*@files where { $_ > 0 && $_.all.IO.f }) {
	my @packages = @files.map({ $_.IO.slurp.&from-json }).flat;
	# convert to hashmap of name: package, for easier reference
	my %packages = @packages.map({ $_.<name> => $_ });

	# TODO: Order by dependencies

	my @backgroundTasks = [];
	for @packages {
		.<chart> ||= .<name>;

		for .<dependencies>[?].map({ %packages{$_} }) {
			with .<waitCommand> { .&shell or fail } 
		}

		my Str $valArgs = .<values>[?].map({" --values $_"}).join;
		my Str $setArgs = .<set>[?].map({" --set {.key}={.value}"}).join;

		my $task = Proc::Async.new(<<
			helm upgrade --install "$_.<name>" "$_.<chart>" --repo "{$_.<repo> // ""}"
				--namespace "$_.<namespace>" --create-namespace
				$valArgs $setArgs
			>>);
		@backgroundTasks.push($task.start);
	}

	await @backgroundTasks;
	for @packages {
		with .<waitCommand> { .&shell || fail }
	}
}
