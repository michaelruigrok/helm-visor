#!/usr/bin/env rakudo
#
# Installs helm packages defined in a pkg JSON file
#
# This file has been over-commented, to assist those new to Raku.
# Please ensure any comments are up-to-date when you edit code.

use YAMLish;

# eg @var[?]. Turn a possible Nil into an empty list []
sub postfix:<[?]>(Any $var) {
	$var // []; # `//` is a null safety operator
}

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
sub helmSetPairs($data) {
	$data.pairs.map({
		my $prefix;
		# ~~ is 'smart match', it does what you want™.
		# In this case checking $data is of type List.
		if $data ~~ List {
			# '$_' is a 'topic variable', the default var name for a lambda/closure.
			# In this case, the element being mapped.
			$prefix = "[{$_.key}]";
		} else {
			# A method call without an object in front will also use the topic variable.
			$prefix = .key;
		}

		# Raku's switch statement. Smart matches .value to each `when`.
		given .value {
			# merge any child structures into the current one, combining keys into a single key
			when Associative { $_.&helmSetPairs.map({ "{$prefix}.{.key}" => .value }).Slip }
			when List        { $_.&helmSetPairs.map({ "{$prefix}{.key}"  => .value }).Slip }
			# a => b is a key-value Pair. Will be added to the parent map directly.
			default          { $prefix => $_          }
		}
	});
}

# MAIN subroutine auto-generates a command-line interface for this program!
sub MAIN(
	Bool :$debug, # named parameter. in MAIN it creates a --flag on the cli
	Bool :$diff,
	Bool :$dry-run,
	Bool :$template,
	*@files where { $_ > 0 && $_.all.IO.f }, # all remaining arguments are put in the @files Array
) {
	# @packages is a list of Maps, where each Map contains the information for a Helm package.
	my @packages = @files.map( -> $file {

		# get yaml/json from file contents
		my $data = load-yaml($file.IO.slurp);

		# put data in an Array (or convert if it's already a list)
		my @data = $data ~~ List ?? $data.Array !! $data; # Ternary. In Raku, ? is a boolifier, and ! is a negated boolifier, so ternary uses same chars.

		# add file as a field to each package
		@data.map({ $_.append('file', $file) })
			.Slip; # Merge all files into a single list
	});

	# default 'chart' field to value of 'name' if not set
	for @packages { .<chart> //= .<name> } # $_<foo> access the value of key 'foo' in map $_

	# hashmap of {name => package}, for easy lookup
	my %packages = @packages.map({ $_.<name> => $_ });

	# test for loops in the dependency chain
	# don't worry about this unless you have to modify the dependency resolution impl.
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
		my $pkg = $_; # for reference in blocks

		for .<dependencies>[?].map({ %packages{$_} }) {
			await %done{.<name>};
			with .<waitCommand> { .&shell or fail }  # bar.&foo runs the bar function on foo
		}

		for @(.<pre-hook>[?]) { .&shell or fail }

		my Str $valArgs = .<values>[?].map(-> $valueFile {" --values {.<file>.IO.dirname}/$valueFile"}).join;
		my Str @setArgs = .<set>[?].&helmSetPairs.map({ |('--set', "{.key}={
			given .value {
				# Appropriately format each value so each argument is interpreted as the correct type
				when 'true'                  { '\"true\"'       }
				when 'false'                 { '\"false\"'      }
				when 'false'                 { '\"false\"'      }
				when { $_ ~~ Str && $_.Num } { '\"' ~ $_ ~ '\"' }
				when * === True              { 'true'           }
				when * === False             { 'false'          }
				default                      { $_               }
			}
		}") });

		sub arg(Str $arg) {
			given $pkg{$arg} {
				when Bool { "--$arg" if $_; }
				default   { $_ ?? "--$arg $_" !! ""; }
			}
		}

		my $task = Proc::Async.new(<< # <<foo bar>> creates an array on each space separator, and quoting groups
			helm {'diff' if $diff}
				{ if $template {
					'template'
				} else {
					'upgrade --install'
				}}
				"$_.<name>" "$_.<chart>"
				# optional args in alphabetical order
				{ '--create-namespace' if not $diff }
				{'--debug' if $debug}
				{'--dry-run' if $dry-run}
				{ arg 'namespace' }
				{ arg 'repo' }
				{ arg 'version' }
				$valArgs
			>>,
			@setArgs,
		);

		with .<name> -> $name {
			$task.start.then({ %done{$name}.keep });
		}
	}

	await %done.values;
	for @packages {
		with .<waitCommand> { .&shell or fail }
	}
}
