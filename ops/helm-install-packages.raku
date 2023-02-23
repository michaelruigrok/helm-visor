#!/usr/bin/env rakudo

use JSON::Fast;

# eg @var[?]. Turn a possible Nil into an empty list []
sub postfix:<[?]>(Any $var) { $var // [] }

sub MAIN(*@files where *.IO.f) {
	my @packages = @files.map({ $_.IO.slurp.&from-json }).flat;
	# convert to hashmap of name: package, for easier reference
	my %packages = @packages.map({ $_.<name> => $_ });

	# TODO: Order by dependencies

	my @backgroundTasks = [];
	for @packages {
		.<chart> ||= .<name>;

		for .<dependencies>[?].map({ %packages{$_} }) {
			with .<waitCommand> { .&shell || fail }
		}

		my Str $valArgs = .<values>[?].map({" --values $_"}).join;
		my Str $setArgs = .<set>[?].map({" --set {.key}={.value}"}).join;

		my $task = Proc::Async.new(qqw{
			helm upgrade --install "{.<name>}" "{.<chart>}" --repo "{.<repo>}" \\
				--namespace "{.<namespace>}" --create-namespace \\
				$valArgs $setArgs
			});
		@backgroundTasks.push($task.start);
	}

	await @backgroundTasks;
	for @packages {
		with .<waitCommand> { .&shell || fail }
	}
}
