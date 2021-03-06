
### Link::C will automatically link your C libraries for you.
use v6;
module Link::C;

constant @HEADER_DIRS = <. /usr/include>, @*INC;
constant @LIBRARY_DIRS = <. /lib /usr/lib>, @*INC;
constant @LIBRARY_EXTS = '', <.so .so.0>;

sub link(
		*@files is copy,
		:$verbose?,
		:$quiet?,
		:$cache = 1,
		:$link = *,
		:$import?,
		:$skip?,
) {
	call_only_once;
	for @files {
		if $_ ~~ /\.<[hc]>$/ {
			resolve_header($_)
		}
		else {
			resolve_library($_)
		}
	}
	 # Find the filename of the calling program, for caching
	my $caller = Q:PIR {
		$P0 = getinterp
		$P0 = $P0['annotations';1]
		%r = $P0['file']
	};
	my $linking_code;
	 # using 'use' picks the .pir file before the .pm file
	 # but if the .pir file does not exist we won't know.
	if $cache and $cache eq 'always' or check_newer("$caller.linkc-cache.pm", $caller, @files) {
		  warn "Using cache" if $verbose;
		$linking_code = "use \"$caller.linkc-cache\"";
	}
	else {
		  warn "Not using cache" if $verbose;
		  warn "Reading headers and libraries" if $verbose;
		readh(@files, :$link, :$skip);
		  warn "Generating code" if $verbose;
		$linking_code = gen_linking_code(:$import);
		if $cache { write_cache($caller, $linking_code, :$verbose, :$quiet) };
	}
	  warn "Linking" if $verbose;
	undefine $!;
	eval $linking_code;
	die $! if $!;
	  warn "Done" if $verbose;
}

sub call_only_once {
	state $already_called;
	$already_called and die "Multiple calls to Link::C are not supported at this time, sorry.\nPlease put all your arguments in one call.\n";
	$already_called = 1;
}

sub resolve_header($f is rw) {
	for @HEADER_DIRS -> $d {
		if "$d/$f" ~~ :e {
			return $f = "$d/$f";
		}
	}  # none found
	die "$f not found in any of " ~ (join ", ", @HEADER_DIRS) ~ "\n";
}

sub resolve_library($f is rw) {
	for @LIBRARY_DIRS -> $d {
		for @LIBRARY_EXTS -> $e {
			if "$d/$f$e" ~~ :e {
				return $f = "$d/$f$e";
			}
		}
	}  # none found
	die "None of "
	  ~ (join ", ", map {"$f$_"}, @LIBRARY_EXTS)
	  ~ " found in any of "
	  ~ (join ", ", @LIBRARY_DIRS)
	  ~ "\n";
}

sub check_newer($file is copy, *@others is copy) {
	return False unless $file ~~ :e;
	$file.=subst("'", "'\\''", :global);  # shell safety
	@others.map: *.=subst("'", "'\\''", :global);
	my $modtime = 'stat -c %Y';  # :M doesn't work
	my $filemodtime = qqx"$modtime '$file'";
	for @others {
		return False if qqx"$modtime '$_'" > $filemodtime;
	}
	return True;
}

sub write_cache($caller, $linking_code is rw, :$verbose, :$quiet) {
	  warn "Creating cache" if $verbose;
	if my $CACHE = open "$caller.linkc-cache.pm", :w {
		$CACHE.print($linking_code) or $quiet or warn "Could not write to cache: $!\n";
		$CACHE.close or $quiet or warn "Could not close cache: $!\n";
		  warn "Precompiling cache" if $verbose;
		my $tmperr = '/tmp/linkc-compile-err-' ~ [~] ('a'..'z', 'A'..'Z', 0..9).pick(5, :replace);
		run("perl6 --target=pir $caller.linkc-cache.pm > $caller.linkc-cache.pir 2> $tmperr");
		if (slurp $tmperr) -> $err {
			warn "Could not precompile cache: $err\n" unless $quiet;
		}
		else {
			$linking_code = "use \"$caller.linkc-cache\"";
		}
		unlink $tmperr or $quiet or warn "Could not unlink $tmperr: $!\n";
	}
	else {
		warn "Could not open $caller.linkc-cache.pm for writing: $!\nWill not cache linking code.\n" unless $quiet;
	}
}


sub readh(*@files is copy, :$link, :$skip) {
	my $readh = join "/", ((@*INC, "..").first({"$_/Link/C/readh.p5" ~~ :e}), "Link/C/readh.p5");
	our %functions;
	for @files {
		.=subst("'", "'\\''");
		$_ = "'$_'";
	}
	my $tmperr = "/tmp/linkc-readh-err-" ~ [~] ('a'..'z', 'A'..'Z', 0..9).pick(5, :replace);
	my $result = qqx"perl '$readh' {@files} 2> $tmperr";
	my $err = slurp $tmperr;
	unlink $tmperr;
	die $err if $err;

	my @skip = $skip ~~ List ?? @($skip) !! $skip;
	my @link = $link ~~ List ?? @($link) !! $link;

	for $result.split("\n")  {
		next when "";
		my @r = .split(' : ');
		next if @r[1] ~~ any(@skip);
		if @r[1] ~~ any(@link) {
			push (%functions{shift @r} //= []), [@r];
		}
	}
}

sub parrot_signature (*@types) {
	[~] map {%PARROT_SIG_TRANS{$_}}, @types
}

sub gen_linking_code(:$import) {
	our %functions;
	[~]
	gen_begin(),
	%functions.keys.map({
		my $lib = $_;
		gen_library_load($lib),
		%functions{$lib}.map(-> $_ {&gen_link_function(:$import, $_)})
	})
}

sub gen_begin {
	$TOP_DECL
}

sub gen_library_load($lib) {
	repl($LOAD_LIB,
		'[[LIB]]' => $lib
	)
}

sub gen_link_function(:$import, @f is copy) {
	my $name = shift @f;
	return "" if @f.grep: {$_ !~~ %PARROT_SIG_TRANS};
	my $ret = shift @f;
	my $export;
	repl($LINK_FUNCTION,
		'[[NAME]]' => $name,
		'[[ARGS]]' => (join ', ', map {"\$p$_"}, 1..@f),
		'[[PARROT_SIG]]' => parrot_signature($ret, @f),
	) ~ 
	do {given $import {
		"" when undef;
		when Array {
			$_[].first({$export = match_export($name, $_)})
			 ?? repl($EXPORT_FUNCTION,
					'[[NAME]]' => $name,
					'[[EXPORT]]' => $export,
			) !! ""
		}
		default {
			($export = match_export($name, $_))
			 ?? repl($EXPORT_FUNCTION,
					'[[NAME]]' => $name,
					'[[EXPORT]]' => $export,
			) !! ""
		}
	}}
}

sub match_export($name, $match) {
	if $match ~~ Pair {
		$name.subst($match.key, $match.value) if $name ~~ $match.key;
	}
	else {
		$name if $name ~~ $match;
	}
}

sub repl (Str $s, *@pairs) {
	my $r = $s;
	for @pairs {
		$r.=subst(.key, .value, :global);
	}
	$r;
}


 # Maybe we should regularize the types some.
 # Parrot's NCI interface does not make a case for unsigned integers.
constant %PARROT_SIG_TRANS = (
	'v'     => 'v',
	'v *'   => 'i',  # Yes we'll keep track.
	'?c'    => 'c',
	'?c *'  => 't',  # This is presumed to be a string.
	'sc'    => 'c',
	'sc *'  => 't',  # If it is not a string, parrot may segfault.
	'uc'    => 'c',
	'uc *'  => 't',
	'si'    => 'i',
	'si *'  => '3',
	'ui'    => 'i',
	'ui *'  => '3',
	'ss'    => 's',
	'ss *'  => '2',
	'us'    => 's',
	'us *'  => '2',
	'sl'    => 'l',
	'sl *'  => '4',
	'ul'    => 'l',
	'ul *'  => '4',
	'f'     => 'f',
	'd'     => 'd',
);

=begin notused
constant %PERL_SIG_TRANS = (
	'void'             => 'Void',
	'char'             => 'int8',
	'char *'           => 'buf8',
	'signed char'      => 'int8',
	'signed char *'    => 'buf8',
	'unsigned char'    => 'uint8',
	'unsigned char *'  => 'buf8',
	'int'              => 'int',
	'int *'            => 'int',
	'signed'           => 'int',
	'signed *'         => 'int',
	'signed int'       => 'int',
	'signed int *'     => 'int',
	'unsigned'         => 'uint',
	'unsigned *'       => 'uint',
	'unsigned int'     => 'uint',
	'unsigned int *'   => 'uint',
	'short'            => 'int16',
	'short *'          => 'int16',
	'short int'        => 'int16',
	'short int *'      => 'int16',
	'signed short'     => 'int16',
	'signed short *'   => 'int16',
	'signed short int' => 'int16',
	'signed short int *' => 'int16',
	'unsigned short'   => 'uint16',
	'unsigned short *' => 'uint16',
	'unsigned short int' => 'uint16',
	'unsigned short int *' => 'uint16',
	'signed long'      => 'int32',
	'signed long *'    => 'int32',
	'signed long int'  => 'int32',
	'signed long int *' => 'int32',
	'unsigned long'    => 'int32',
	'unsigned long *'  => 'int32',
	'unsigned long int' => 'int32',
	'unsigned long int *' => 'int32',
	'float'            => 'num32',
	'double'           => 'num64',
);
=end notused

constant $TOP_DECL =
Q/Q:PIR {
	.local pmc lib
	.local pmc func
	.local string failstr
	goto begin
	error:
		if failstr goto knownerror
			$P0 = new 'Exception'
			$P0 = "Library load failed.\n"
			throw $P0
		knownerror:
			$P0 = new 'Exception'
			$P0 = failstr
			throw $P0
	begin:
};
/;

constant $LOAD_LIB =
Q/Q:PIR {
	lib = loadlib '[[LIB]]'
	failstr = "Failed to load [[LIB]]\n"
	unless lib goto error
};
/;

constant $LINK_FUNCTION =
Q/Q:PIR {
	func = dlfunc lib, '[[NAME]]', '[[PARROT_SIG]]'
	set_hll_global ['Link';'C';'NCI'], '$[[NAME]]', func
};
&C::[[NAME]] = sub [[NAME]] ([[ARGS]]) { $Link::C::NCI::[[NAME]]([[ARGS]]) }
/;

constant $EXPORT_FUNCTION =
Q/our &[[EXPORT]] := &C::[[NAME]];
/;
