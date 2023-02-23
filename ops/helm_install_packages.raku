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
	sub checkDependencies(@branch) {
		my $tail = @branch[*-1];
		for %packages{$tail}<dependencies> // [] {
			if $_ (elem) @branch { die "Dependency $_ contains circular loop: {@branch}" }
			checkDependencies([|@branch, $_]);
		}
	}
	for @packages { checkDependencies([.<name>]) }

	# create a hash of dependency -> package
	# used to find what package to try and install next
	my %next;
	for @packages -> %package {
		for %package<dependencies> // [] -> $dependency {
			if not %next{$dependency}:exists {
				%next{$dependency} //= [];
			}
			%next{$dependency}.push(%package<name>);
		}
	}

	my @backgroundTasks = [];

	sub installPackage($_) {
		return if .<done>;
		for .<dependencies>[?] {
			return if $_ and not %packages{$_}.<done>;
		}

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
		my $promise = $task.start;
		@backgroundTasks.push($promise);

		.<done> = True;

		# add to queue any packages that have this one as a dependency
		for %next{.<name>}[?] -> $next {
			@backgroundTasks.push($promise.then({
				installPackage(%packages{$next});
			}));
		}
	}

	for @packages { installPackage($_); }

	await @backgroundTasks;
	for @packages {
		with .<waitCommand> { .&shell || fail }
	}
}
