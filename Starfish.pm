# Starfish - Perl-based System for Preprocessing and Text-Embedded Programming
#
# (c) 2001-2020 Vlado Keselj http://web.cs.dal.ca/~vlado vlado@dnlp.ca
#               and contributing authors
#
# See the documentation following the code.  You can also use the
# command "perldoc Starfish.pm".

package Text::Starfish;
use vars qw($NAME $ABSTRACT $VERSION); use strict;
$NAME     = 'Text::Starfish';
$ABSTRACT = 'Perl-based System for Preprocessing and Text-Embedded Programming';
$VERSION  = '1.39';

use POSIX;
use Carp;
use Cwd qw(cwd);
use Exporter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS); # Exporter vars

@ISA = qw(Exporter);
%EXPORT_TAGS = ( 'all' => [qw(
  add_hook appendfile echo file_modification_date 
  file_modification_time getfile getmakefilelist get_verbatim_file
  getinclude htmlquote include
  last_update putfile read_records read_starfish_conf rm_hook set_out_delimiters
  sfish_add_tag sfish_ignore_outer starfish_cmd make_gen_dirs_to_generate
  make_add_dirs_to_generate_if_needed
  ) ] );
@EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
@EXPORT = @{ $EXPORT_TAGS{'all'} };

# Used in starfishing Makefiles
use vars qw(@DirGenerateIfNeeded);

# non-exported package globals
use vars qw($GlobalREPLACE);

sub appendfile($@);
sub getfile($ );
sub getmakefilelist($$);
sub htmlquote($ );
sub putfile($@);
sub read_records($ );
sub starfish_cmd(@);

sub new($@) {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self = {};
  bless($self, $class);

  $self->{Loops} = 1;
  my $copyhooks = '';
  foreach (@_) {
    if (/^-infile=(.*)$/) { $self->{INFILE} = $1 }
    elsif (/^-copyhooks$/)   { $copyhooks = 1 }
    else { _croak("unknown new option: $_") }
  }

  if ($copyhooks) {
    _croak("new: cannot copyhooks if Star is not there") unless
      ref($::Star) eq 'Text::Starfish';
    $self->{Style}           = $::Star->{Style};
    $self->{CodePreparation} = $::Star->{CodePreparation};
    $self->{LineComment}     = $::Star->{LineComment};
    $self->{OutDelimiters}   = $::Star->{OutDelimiters};
    $self->{IgnoreOuter}     = $::Star->{IgnoreOuter};
    $self->{hook}            = [ @{ $::Star->{hook} } ];
  }

  $self->set_style() unless $copyhooks;

  return $self;
}

sub starfish_cmd(@) {
  my $sf = Text::Starfish->new();
  my @tmp = ();
  foreach (@_) {
    if    (/^-e=?/)      { $sf->{INITIAL_CODE} = $' }
    elsif (/^-mode=/)    { $sf->{NEW_FILE_MODE} = $' }
    elsif (/^-o=/)       { $sf->{OUTFILE}      = $' }
    elsif (/^-replace$/) { $sf->{REPLACE} = $GlobalREPLACE = 1; }
    elsif (/^-v$/) { print "$NAME, version $VERSION, $ABSTRACT\n"; exit 0; }
    else { push @tmp, $_ }
  }

  if (defined $sf->{NEW_FILE_MODE} and $sf->{NEW_FILE_MODE} =~ /^0/)
  { $sf->{NEW_FILE_MODE} = oct($sf->{NEW_FILE_MODE}) }

  $sf->process_files(@tmp);
  return $sf;
}

sub include($@) { $::O .= getinclude(@_); return 1; }

sub getinclude($@) {
  my $sf = loadinclude(@_);
  return '' unless defined $sf;
  $sf->_digest();
  return $sf->{Out}; }

sub loadinclude($@) {
  my $infile = '';
  my @args = ();
  my $replace = 1;
  my $require = '';
  foreach (@_) {
    if    (/^-replace$/)   { $replace = 1 }
    elsif (/^-noreplace$/) { $replace = '' }
    elsif (/^-require$/)   { $require = 1 }
    elsif (!/^-/ && $infile eq '') { $infile = $_ }
    else  { push @args, $_ }
  }

  my $sf = Text::Starfish->new("-infile=$infile", @args);
  $sf->{REPLACE} = $replace;

  if ($sf->{INFILE} eq '' or ! -r $sf->{INFILE} ) {
    if ($require) { _croak("cannot getinclude file: ($sf->{INFILE})") }
    return undef;
  }

  $sf->{data} = getfile $sf->{INFILE};
  return $sf; }

sub process_files {
  my $self = shift;
  my @args = @_;

  if (defined $self->{REPLACE} and !defined $self->{OUTFILE})
  { _croak("Starfish:output file required for replace") }

  my $FileCount=0;
  $self->eval1($self->{INITIAL_CODE}, 'initial');

  while (@args) {
    $self->{INFILE} = shift @args;
    ++$FileCount;
    $self->set_style();
    $self->{data} = getfile $self->{INFILE};

    # *123* we need to forbid defining an outfile externally as well as
    # internally:
    my $outfileExternal = exists($self->{OUTFILE}) ? $self->{OUTFILE} : '';

    my $ExistingText = '';
    if (! defined $self->{OUTFILE}) {
      $ExistingText = $self->{data};
      $self->{LastUpdateTime} = (stat $self->{INFILE})[9];
    }
    elsif ($FileCount > 1)  {
      $ExistingText = '';
      $self->{LastUpdateTime} = time;
    }
    elsif (! -f $self->{OUTFILE})   {
      $ExistingText = '';
      $self->{LastUpdateTime} = time;
    }
    else {
      $ExistingText = getfile $self->{OUTFILE};
      $self->{LastUpdateTime} = (stat $self->{OUTFILE})[9];
    }

    $self->_digest();

    # see *123* above
    if ($outfileExternal ne '' and $outfileExternal ne $self->{OUTFILE})
    { _croak("OUTFILE defined externally ($outfileExternal) and ".
	     "internally ($self->{OUTFILE})") }

    my $InFile = $self->{INFILE};
    if ($FileCount==1 && defined $self->{OUTFILE}) {
      # touch the outfile if it does not exist
      if ( ! -f $self->{OUTFILE} ) {
	putfile $self->{OUTFILE};
	my $infile_mode = (stat $InFile)[2];
	if (defined $self->{NEW_FILE_MODE}) {
	       chmod $self->{NEW_FILE_MODE}, $self->{OUTFILE}}
	else { chmod $infile_mode,	$self->{OUTFILE} }
      }
      elsif (defined $self->{NEW_FILE_MODE}) {
	chmod $self->{NEW_FILE_MODE}, $self->{OUTFILE} }
    }

    # write the text if changed
    if ($ExistingText ne $self->{Out}) {
      if (defined $self->{OUTFILE}) {
	# If the OutFile is defined, we may have to play with
	# permissions in order to write.  Be careful! Allow
	# unallowed write only on outfile and if -mode is
	# specified
	my $mode = ((stat $self->{OUTFILE})[2]);
	if (($mode & 0200) == 0 and defined $self->{NEW_FILE_MODE}) {
	  chmod $mode|0200, $self->{OUTFILE};
	  if ($FileCount==1) { putfile $self->{OUTFILE}, $self->{Out} }
	  else            { appendfile $self->{OUTFILE}, $self->{Out} }
	  chmod $mode, $self->{OUTFILE};
	} else {
	  if ($FileCount==1) { putfile $self->{OUTFILE}, $self->{Out} }
	  else            { appendfile $self->{OUTFILE}, $self->{Out} }
	}
      }
      else {
	putfile $InFile, $self->{Out};
	chmod $self->{NEW_FILE_MODE}, $InFile if defined $self->{NEW_FILE_MODE};
      }
    }
    elsif (defined $self->{NEW_FILE_MODE}) {
      if (defined $self->{OUTFILE}) {
	     chmod $self->{NEW_FILE_MODE}, $self->{OUTFILE} }
      else { chmod $self->{NEW_FILE_MODE}, $InFile }
    }
  }				# end of while (@args)

}				# end of method process_files

sub _digest {
  my $self = shift;
  $self->{CurrentLoop} = 1;
  my $savedcontent = $self->{data};
  
 START:			# The main scanning loop
  $self->{Out} = '';
  $self->_scan();
  while ($self->{ttype} != -1) {
    if ($self->{ttype} > -1) {
      $self->{Out} .= $self->_evf_dispatch;
    } # else $ttype < -1 (outer text)
    else { $self->_process_outer( $self->{currenttoken} ) }
    $self->_scan(); }
    
  if ($self->{CurrentLoop} < $self->{Loops}) {
    ++$self->{CurrentLoop};
    if ($self->{REPLACE}) {             # in replace mode interate with
      $self->{data} = $savedcontent;    # original input
      goto START; }
    $self->{data} = $self->{Out};
    if ($savedcontent ne $self->{Out})
      { $self->{LastUpdateTime} = time }
    putfile 'sfish.debug', $self->{data};
    goto START; }

  # Final routines, if defined
  if (defined($self->{Final})) {
    my @a = @{ $self->{Final} };
    local $::Star = $self;
    for my $f (@a) {
      $self->{Out} = &{$f}($self->{Out}); }}
  
  # Related to the macro concept (e.g. code folding)
  if (defined $self->{macrosdefined}) {
    my ($m, $s);
    for $m (sort keys %{$self->{Macros}}) {
      $s = $self->{Macros}->{$m};
      if ($s =~ /\n/) {
	my $p1 = "$`$&"; $s = $';
	if ($s) { $s = $p1.wrap($s) }
	else { $s = $p1 }
      }
      $self->{Out}.= $self->{MprefAuxDefine}.$s.$self->{MsufAuxDefine};
    }
  }
} # end of sub _digest

# process outer text; by default, it should be appended to $self->{Out}
sub _process_outer {
  my $self = shift; my $outer = shift;
  if ($self->{REPLACE} && $self->{IgnoreOuter}) {  }
  else { $self->{Out} .= $outer }
  # Comment: something should be done if IgnoreOuter is true and
  # not in REPLACE mode; maybe comment-out outer text? (todo?)
}

# _index($str,$substr) or _index($str, qr/../)
# returns index and length of found match, index==-1 for not found
# third argument is an optional offset
sub _index {
  my $str = shift; my $subs = shift; my $off = shift;
  if (ref($subs) eq 'Regexp') {
    if ($off < 1) {
      if ($str =~ $subs) { return (length($`),length($&)) }
      else { return (-1,0) }
    } else {
      pos($str) = $off;
      if ($str =~ /$subs/g) { return (length($`),length($&)) }
      else { return (-1,0) }
    }
  }
  elsif ($off < 1) { return (index($str, $subs), length($subs)) }
  else { return (index($str, $subs, $off), length($subs)) }
}

# Scanning for the best hook match
sub _scan_for_hook_match {
  my $self = shift;
  $self->{prefix} = $self->{suffix} = '';
  $self->{args} = [];
      
  my $i1 = length($self->{data}) + 1;   # distance to starting anchor
  my $i2 = $i1;                         # distance to ending anchor
  my $pl=0; my $sl=0;                   # prefix and suffix lengths
  $self->{ttype} = -2;                  # token type == hook id
  foreach my $ttype (0 .. $#{ $self->{hook} }) {
    my $hook = $self->{hook}->[$ttype];
    my ($j, $pl2, $j2, $sl2); # current token under consideration,
                              # $j  dist to candidate starting achor
                              # $j2 dist to candidate ending anchor
                              # pl2 and sl2 - lengths of prefix and suffix
    my $ht = $hook->{ht};
    if ($ht eq '') { # guessing hook type if not defined
      if (exists($hook->{begin})) { $ht = $hook->{ht} = 'be' }
      else { $ht = $hook->{ht} = 'regex' } }

    if ($ht eq 'string') {
      ($j,$pl2) = _index($self->{data}, $hook->{s});
      next unless $j != -1 && $j <= $i1;
      next if $j==$i1 and $i2<=$j+$pl2;
      $i1 = $j; $pl = $pl2; $self->{ttype} = $ttype; $self->{args} = [];
      $i2 = $i1+$pl; $sl = 0;
    } elsif ($ht eq 'be') {
      ($j,$pl2) = _index($self->{data}, $hook->{'begin'});
      next unless $j != -1 && $j <= $i1;
      if ($hook->{'end'} ne '') {
	($j2, $sl2) = _index($self->{data}, $hook->{'end'}, $j);
	next if -1 == $j2;
      } else { $j2 = length($self->{data}) + 1; $sl2 = 0; }
      next if ($j==$i1 and $i2<=$j2);
      $i1 = $j; $pl = $pl2; $i2 = $j2; $sl = $sl2;
      $self->{ttype} = $ttype; $self->{args}  = [];
    } elsif ($ht eq 'regex') {
      my @args = ($self->{data} =~ /$hook->{regex}/m);
      next unless @args;
      my $j = length($`);
      next unless $j < $i1;
      $i1 = $j; $i2 = $i1+length($&); $sl=$pl=0;
      unshift @args, $&; # could be removed
      $self->{ttype} = $ttype;
      $self->{args} = \@args;
    } elsif ($ht eq 'ht:re2') {
      my @args = ($self->{data} =~ /$hook->{regex}/m);
      next unless @args;
      my $j = length($`);
      next unless $j < $i1;
      $i1 = $j; $i2 = $i1+length($&); $sl=$pl=0;
      unshift @args, $&; # full match is prepended to @args !?to remove?
      $self->{ttype} = $ttype;
      $self->{args} = \@args;
    } else { _croak("Unknown hook type: ($ht)"); }
  }
  $self->{match_ij} = [$i1,$i2,$pl,$sl];
}

# $self->{ttype}: -1 EOF
#             -2 outer text (but also handled directly)
sub _scan {
  my $self = shift;
  $self->{prefix} = $self->{suffix} = ''; $self->{args} = [];
  if ($self->{data} eq '') {	# no more data, EOF
    $self->{ttype} = -1;        # ttype==-1 is EOF
    $self->{currenttoken} = '';
  }
  else {
    $self->_scan_for_hook_match();
    my ($i1,$i2,$pl,$sl) = @{ $self->{match_ij} };
    if ($self->{ttype}==-2) {
      $self->{currenttoken}=$self->{data}; $self->{data}='' }
    else { # live code
	# just copy type -2
	# instead of returning as earlier, to
	# support negative look-back for prefix
	# $self->{Out} .= substr($self->{data}, 0, $i1);
	$self->_process_outer( substr($self->{data}, 0, $i1) );
	$self->{prefix} = substr($self->{data}, $i1, $pl);
	$self->{currenttoken} = substr($self->{data}, $i1+$pl, $i2-$i1-$pl);
	$self->{suffix} = substr($self->{data}, $i2, $sl);
	$self->{data} = substr($self->{data}, $i2+$sl);
	# Remove old output if it is there:
	if (defined($self->{OutDelimiters})) {
	  my ($b1,$b2,$e1,$e2) = @{ $self->{OutDelimiters} };
	  if ($self->{data} =~ /^\Q$b1\E(\d*)\Q$b2\E.*?\Q$e1\E\1\Q$e2\E/s) {
	    $self->{data} = $'; }
	}
      }
  }
  return $self->{ttype};
}

# _evf_dispatch should decide how to properly call the evaluator (evf), or just
# apply replacement.  It should eventually be used for string-based evaluators.
sub _evf_dispatch {
  my $self = shift;
  my $hook = $self->{hook}->[$self->{ttype}]; my $ht = $hook->{ht};
  local $::Star = $self;
  local $::O = '';
  if ($ht eq 'string') { $::O .= $hook->{evf_const};
  } elsif ($hook->{ht} eq 'regex') {
    $::O .= &{ $hook->{replace} } ( $self, @{ $self->{args} } ); #!!!
  } elsif ($hook->{ht} eq 'ht:re2') { #!!! python/make style eval
                                   # evaluation function uses its own output
                                   # wrap and attachement.
    return &{$hook->{replace}}( $self, @{ $self->{args} } );
  } elsif ( @{$self->{args}} ) { # guessing regex hook type
    return &{$hook->{replace}}( $self, @{ $self->{args} } );
  } else {
    return &{$hook->{f}}
      ( $self, $self->{prefix}, $self->{currenttoken}, $self->{suffix});
  }

  return $::O if $self->{REPLACE};
  return $self->{currenttoken} if $::O eq '';
  return $self->{currenttoken}.
         $self->_output_wrap( $::O );
}

# eval wrapper for string code
sub eval1 {
  my $self = shift;
  my $code = shift; $code = '' unless defined $code;
  my $comment = shift;
  eval("package main; no strict; $code");
  if ($@) {
    my ($code1, $linecnt);
    foreach (split(/\n/, $code))
      { ++$linecnt; $code1 .= sprintf("%03d %s\n", $linecnt, $_); }
    _croak("$comment code error:$@\ncode:\n$code1");
  }
}

# The main subroutine for evaluating a snippet of string
sub _evaluate {
  my $self = shift;

  my $pref = shift;
  my $code = shift; my $c = $code;
  my $suf = shift;
  if (defined($self->{CodePreparation}) && $self->{CodePreparation}) {
    local $_=$code;
    $self->eval1($self->{CodePreparation},'preprocessing');
    $code = $_; }

  # Evaluate code, first final preparation and then eval1
  local $::Star = $self;
  local $::O = '';
  $self->eval1($code, 'snippet');
 
  if ($self->{REPLACE}) { return $::O }
  if ($::O ne '') { $suf.= $self->_output_wrap($::O); }	  
  return "$pref$c$suf"; }

# Wrap output with output delimiters
sub _output_wrap {
  my $self = shift; my $out = shift; my @d = ("#","+\n","#","-");
  @d = @{ $self->{OutDelimiters} } if defined( $self->{OutDelimiters} );
  my ($b,$e) = ($d[0].$d[1], $d[2].$d[3]); my $i;
  if (index($out, $e) != -1) {
    while(1) { $i++; $e=$d[2].$i.$d[3]; last if index($out, $e)==-1;
      _croak("Problem finding ending delimiter!\n(O=$out)") if $i > 1000000;}
    $b = $d[0].$i.$d[1]; }
  return $b.$out.$e; }

# Python-specific evaluator (used also for makefile style)
# used with hook type ht:re2
sub evaluate_py1 { #!!!py
  my $self = shift;
  my $allmatch = shift; #!!!py maybe to remove it!?
  my $indent = shift;
  my $prefix = shift;
  my $code = shift; my $c = $code;
  my $oldout = shift; #!?to remove it

  if (defined($self->{CodePreparation}) && $self->{CodePreparation}) {
    local $_=$code;
    $self->eval1($self->{CodePreparation},'preprocessing');
    $code = $_;
  }

  # Evaluate code, first final preparation and then eval1
  local $::O = '';
  local $::Star = $self;
  $self->eval1($code, 'snippet');

  if ($self->{REPLACE}) { return $indent.$::O }
  elsif ($::O eq '') { return "$indent#$prefix$c!>" }
  else {
    $::O =~ s/^/$indent/gmx;
    my $r;
    my ($b,$e); my @d = @{ $self->{OutDelimiters} };
    $b = $d[0].$d[1]; my $i; $e = $d[2].$d[3];
    if (index($::O, $e) != -1) {
      while(1) { $i++; $e=$d[2].$i.$d[3]; last if index($::O, $e)==-1;
		 _croak("Problem finding ending delimiter!\n(O=$::O)")
		   if $i > 1000000; }
      $b = $d[0].$i.$d[1];
    }
    $r= "$indent#$prefix$c!>$b".$::O;
    $r =~ s/\n?$/\n/; $r.="$indent$e"; # no extra \n
  }
}

# predefined evaluator: echo
sub eval_echo {
    my $self = shift;
    my $pref = shift;
    my $cont = shift;
    my $suff = shift;
    $::O = $cont;

    # to update OutDelimiters
    return $::O if $self->{REPLACE};
    return $pref.$cont.$suff if $::O eq '';
    $suff.=$self->_output_wrap($::O);
    return $pref.$cont.$suff;
}

# predefined evaluator: ignore
sub eval_ignore {
    my $self = shift;
    return '' if $self->{REPLACE};

    my $pref = shift;
    my $code = shift;
    my $suf = shift;
    return $pref.$code.$suf;
}

# predefined ignore evaluator for regex hooks
sub repl_comment {
    my $self = shift;
    if ($self->{REPLACE}) { return '' }
    return $self->{currenttoken};
}

sub define {
    my $self = shift;

    my $pref = shift;
    my $data = shift;
    my $suf = shift;

    if ($self->{CurrentLoop} > 1) { return "$pref$data$suf"; }

    $data =~ /^.+/ or _croak("expected macro spec");
    _croak("no macro spec") unless $&;
    _croak("double macro def (forbidden):$&") if ($self->{ForbidMacro}->{$&});
    $self->{Macros}->{$&} = $data;
    return '';
}

sub MCdefine {
    my $self = shift;
    my $pref = shift;
    my $data = shift;
    my $suf = shift;

    if ($self->{CurrentLoop} > 1) { die "define in loop > 1 !?" }

    $data =~ /^.+/ or die "expected macro spec";
    die "no macro spec" unless $&;
    die "double macro def (forbidden):$&" if ($self->{ForbidMacro}->{$&});
    $self->{Macros}->{$&} = $data;
    return '';
}

sub MCdefe {
  my $self = shift;
  die "(".ref($self).")" unless ref($self) eq 'Text::Starfish';

  my $pref = shift;
  my $data = shift;
  my $suf = shift;

  if ($self->{CurrentLoop} > 1) { die "defe in a loop >1!?" }

  $data =~ /^.+/ or die "expected macro spec";
  die "no macro spec" unless $&;
  die "def macro forbidden:$&\n" if (defined $self->{ForbidMacro}->{$&});
  $self->{Macros}->{$&} = $data;
  return $self->{MacroKey}->{'expand'}.$&.$self->{MacroKey}->{'/expand'};
}

sub MCnewdefe {
    my $self = shift; die "(".ref($self).")" unless ref($self) eq 'Text::Starfish';

    my $pref = shift;
    my $data = shift;
    my $suf = shift;

    if ($self->{CurrentLoop} > 1) { die "newdefe in second loop!?" }

    $data =~ /^.+/ or die "expected macro spec";
    die "no macro spec" unless $&;
    if (defined $self->{Macros}->{$&} || $self->{ForbidMacro}->{$&}) {
	die "double def:$&" }
    $self->{Macros}->{$&} = $data;
    $self->{ForbidMacro}->{$&} = 1;
    return $self->{MprefExpand}.$&.$self->{MsufExpand};
}

sub expand {
  my $self = shift;
  die "(".ref($self).")" unless ref($self) eq 'Text::Starfish';

  my $pref = shift;
  my $data = shift;
  my $suf = shift;

  if ($self->{CurrentLoop} < 2 || $self->{HideMacros})
  { return $self->{MacroKey}->{'expand'}.$data.$self->{MacroKey}->{'/expand'} }
    
  $data =~ /^.+/ or die "expected macro spec";
  die "no macro spec" unless $&;
  return $self->{MacroKey}->{'expanded'}.$self->{Macros}->{$&}.
    $self->{MacroKey}->{'/expanded'};
}

sub MCexpand {
  my $self = shift;
  die "(".ref($self).")" unless ref($self) eq 'Text::Starfish';

  my $pref = shift;
  my $data = shift;
  my $suf = shift;

  if ($self->{CurrentLoop} < 2 || $self->{HideMacros}) {
    return "$pref$data$suf"; }
    
  $data =~ /^.+/ or die "expected macro spec";
  die "no macro spec" unless $&;
  die "macro not defined" unless defined $self->{Macros}->{$&};
  return $self->{MprefExpanded}.$self->{Macros}->{$&}.$self->{MsufExpanded};
}

sub fexpand {
  my $self = shift;
  die "(".ref($self).")" unless ref($self) eq 'Text::Starfish';

  my $pref = shift;
  my $data = shift;
  my $suf = shift;

  if ($self->{CurrentLoop} < 2) { return "$pref$data$suf"; }
    
  $data =~ /^.+/ or die "expected macro spec";
  die "no macro spec" unless $&;
  die "macro not defined:$&" unless defined $self->{Macros}->{$&};
  return $self->{MpreffExpanded} . $self->{Macros}->{$&}.$self->{MsuffExpanded};
}

sub MCfexpand {
  my $self = shift;
  die "(".ref($self).")" unless ref($self) eq 'Text::Starfish';

  my $pref = shift;
  my $data = shift;
  my $suf = shift;

  if ($self->{CurrentLoop} < 2) { return "$pref$data$suf"; }
    
  $data =~ /^.+/ or die "expected macro spec";
  die "no macro spec" unless $&;
  die "macro not defined:$&" unless defined $self->{Macros}->{$&};
  return $self->{MacroKey}->{'fexpanded'}.$self->{Macros}->{$&}.
    $self->{MacroKey}->{'/fexpanded'};
}

sub expanded {
  my $self = shift;
  die "(".ref($self).")" unless ref($self) eq 'Text::Starfish';

  my $pref = shift;
  my $data = shift;
  my $suf = shift;
    
  $data =~ /^.+/ or die "expected macro name";
  die "no macro spec" unless $&;
  return $self->{MprefExpand}.$&.$self->{MsufExpand};
}

sub MCexpanded {
  my $self = shift;
  die "(".ref($self).")" unless ref($self) eq 'Text::Starfish';

  my $pref = shift;
  my $data = shift;
  my $suf = shift;
    
  $data =~ /^.+/ or die "expected macro name";
  die "no macro spec" unless $&;
  return $self->{MacroKey}->{'expand'}.$&.$self->{MacroKey}->{'/expand'};
}

sub fexpanded {
  my $self = shift;
  die "(".ref($self).")" unless ref($self) eq 'Text::Starfish';

  my $pref = shift;
  my $data = shift;
  my $suf = shift;
    
  $data =~ /^.+/ or die "expected macro name";
  die "no macro spec" unless $&;
  return $self->{MpreffExpand}.$&.$self->{MsuffExpand};
}

sub MCfexpanded {
  my $self = shift;
  die "(".ref($self).")" unless ref($self) eq 'Text::Starfish';

  my $pref = shift;
  my $data = shift;
  my $suf = shift;
    
  if ($self->{CurrentLoop} < 2) { return "$pref$data$suf"; }
  $data =~ /^.+/ or die "expected macro name";
  die "no macro spec" unless $&;
  die "Macro not defined:$&" unless defined $self->{Macros}->{$&};
  return $self->{MacroKey}->{'fexpanded'}.$self->{Macros}->{$&}.
    $self->{MacroKey}->{'/fexpanded'};
}

sub MCauxdefine {
  my $self = shift;
  die "(".ref($self).")" unless ref($self) eq 'Text::Starfish';

  my $pref = shift;
  my $data = shift;
  my $suf = shift;
    
  $data =~ /^.+/ or die "expected macro name";
  die "no macro spec" unless $&;
  my $mn = $&;
  $data = unwrap($data);
  die "double macro def (forbidden):$mn\n" if ($self->{ForbidMacro}->{$mn});
  if (! defined($self->{Macros}->{$mn}) ) { $self->{Macros}->{$mn}=$data }
  return '';
}

sub auxDefine {
  my $self = shift;
  die "(".ref($self).")" unless ref($self) eq 'Text::Starfish';

  my $pref = shift;
  my $data = shift;
  my $suf = shift;
    
  $data =~ /^.+/ or die "expected macro name";
  die "no macro spec" unless $&; my $mn = $&;
  $data = unwrap($data);
  die "double macro def (forbidden):$mn\n" if ($self->{ForbidMacro}->{$mn});
  if (! defined($self->{Macros}->{$mn}) ) { $self->{Macros}->{$mn}=$data }
  return '';
}

sub wrap {
    my $d = shift;
    $d =~ s/^/\/\/ /mg;
    return $d;
}

sub unwrap {
    my $d = shift;
    $d =~ s/^\/\/ //mg;
    return $d;
}

sub setGlobStyle {
    my $self = shift;
    my $s = shift;
    $self->{STYLE} = $s;
    $self->set_style($s);
}

sub clearStyle {
  my $self = shift;
  foreach my $k (qw(Style CodePreparation LineComment OutDelimiters
                    IgnoreOuter)) {
    delete $self->{$k} }
  $self->{hook} = [];
}

sub setStyle { return &set_style }

# List of fields typically set in set_style:
# $self->{Style}           = string, style
# $self->{CodePreparation} = scalar
# $self->{LineComment}     = string, line comment
# $self->{OutDelimiters}   = [] eg: "//" "+\n" "//" "-\n"
# $self->{IgnoreOuter}     = 1 or ''
# $self->{hook}            = [], list of hooks
sub set_style {
  my $self = shift;
  if (ref($self) ne 'Text::Starfish') { unshift @_, $self; $self = $::Star; }

  if ($#_ == -1) {
    if (defined $self->{STYLE} && $self->{STYLE} ne '')
    { $self->set_style($self->{STYLE}) }
    else {
      my $f = $self->{INFILE};

      if ($f =~ /\.(html\.sfish|sf)$/i) { $self->set_style('html.sfish') }
      else {
	$f =~ s/\.s(tar)?fish$//;
	if    ($f =~ /\.html?/i)        { $self->set_style('html') }
	elsif ($f =~ /\.(?:la)?tex$/i)  { $self->set_style('tex') }
	elsif ($f =~ /\.java$/i)        { $self->set_style('java') }
	elsif ($f =~ /^[Mm]akefile/)    { $self->set_style('makefile') }
	elsif ($f =~ /\.ps$/i)          { $self->set_style('ps') }
	elsif ($f =~ /\.py$/i)          { $self->set_style('python') }
	else { $self->set_style('perl') }
      }
    }
    return;
  }

  my $s = shift;
  if ($s eq 'latex' or $s eq 'TeX') {	$s = 'tex' }
  if (defined $self->{Style} and $s eq $self->{Style}) { return }
    
  # default
  $self->clearStyle();
  $self->{'LineComment'} = '#';
  $self->{'IgnoreOuter'} = '';
  $self->{OutDelimiters} = [ "#", "+\n", "#", "-" ];
  $self->{CodePreparation} = 's/\\n(?:#|%|\/\/+)/\\n/g';
  $self->{hook} = [];
  $self->add_hook('be','#<?','!>');
  $self->add_hook('be','<?' ,'!>');
  $self->add_hook('be','<?starfish','?>');

  #!!!py
  # Used for Python and Makefile with &evaluate_py1
  # matched with hook type ht:re2
  my $re_py1 = qr/([\ \t]*)\#(\ *<\?)([\000-\377]*?)!>/x;
  # extension below was a bug for <?...!>...<?...!>#+...#-
  # ([\ \t]*\#+\n[\000-\377]*?\n[\ \t]*\#-\n)?/x;

  if ($s eq 'perl') { }
  elsif ($s eq 'makefile') {
    $self->{CodePreparation} = 's/\\n\\s*#/\\n/g';
    $self->{hook} = [ ];
    $self->add_hook('ht:re2', $re_py1, \&evaluate_py1); #!!!
  }
  elsif ($s eq 'python') {
    $self->{hook} = [ ];
    $self->{CodePreparation} = 's/\\n\\s*#/\\n/g';
    $self->add_hook('ht:re2', $re_py1, \&evaluate_py1); #!!!
  }
  elsif ($s eq 'java') {
    $self->{LineComment} = '//';
      $self->{OutDelimiters} = [ "//", "+\n", "//", "-" ];
      $self->{hook} = [{begin => '//<?', end => '!>', f => \&_evaluate },
		       {begin => '<?', end => '!>', f => \&_evaluate }];
      $self->{CodePreparation} = 's/^\s*\/\/+//mg';
    }
    elsif ($s eq 'tex') {
      $self->{LineComment} = '%';
      # change OutDelimiters ?
      # $self->{OutDelimiters} = [ "%", "+\n", "%", "-\n" ];
      $self->{OutDelimiters} = [ "%", "+\n", "\n%", "-\n" ];
      $self->{hook}=[{ht=>'be', begin=>'%<?', end=>"!>\n", f=>\&_evaluate },
		     # change to this one?
		     #{ht=>'be', begin=>'%<?', end=>"!>", f=>\&_evaluate },
		     {ht=>'be', begin=>'<?', end=>"!>\n", f=>\&_evaluate },
		     {ht=>'be', begin=>'<?', end=>"!>", f=>\&_evaluate }];

      $self->{CodePreparation} = 's/^[ \t]*%//mg';
    }
    elsif ($s eq 'html.sfish') {
      undef $self->{LineComment};
      $self->{OutDelimiters} = [ "<!-- +", " -->", "<!-- -", " -->" ];
      $self->{CodePreparation} = '';
      $self->{hook}=[];
      $self->add_hook('be', '<!--<?', '!>-->');
      $self->add_hook('be', qr/<\?starfish\b/, '?>');
      $self->add_hook('be', qr/<\?sf\b/, '!>');
      $self->add_hook('regex', qr/^#.*\n/m, 'comment');
    }
    elsif ($s eq 'html') {
      undef $self->{LineComment}; # Changes
      $self->{OutDelimiters} = [ "<!-- +", " -->", "<!-- -", " -->" ];
      $self->{hook}=[
	{ht=>'be', begin => '<!--<?', end => '!>-->', f => \&_evaluate },
	{ht=>'be', begin=>'<?starfish ', end=>'?>', f=>\&_evaluate } ];
      $self->{CodePreparation} = '';
    }
    elsif ($s eq 'ps') {
      $self->{LineComment} = '%';
      $self->{OutDelimiters} = [ "% ", "+\n", "% ", "-" ];      
      $self->{hook}=[
         {ht=>'be', begin => '<?', end => '!>', f => \&_evaluate }];
      $self->{CodePreparation} = 's/\\n%/\\n/g';
    }
    else { _croak("set_style:unknown style:$s") }
    $self->{Style} = $s;
}

# to be deprecated?  Used only to make it available in name space
sub sfish_add_tag($$)     { $::Star->add_tag(@_) }
sub sfish_ignore_outer    { $::Star->ignore_outer(@_) }

# adds tags such as %slide:.* and %<slide> by adding appropriate hooks
# eg: add_tag('slide', 'ignore')
# eg: add_tag('sl,l',  'echo')
sub add_tag {
  my $self = shift;
  if (ref($self) ne 'Text::Starfish')
  { unshift @_, $self; $self = $::Star; }
  my $tag = shift; my $fun = shift;
  my $lc = $self->{LineComment};
  #die "tag=($tag) fun=($fun) ref(fun)=".ref($fun);
  if (ref($fun) eq '') {
    if    ( $fun eq 'ignore') { $fun = sub{''} }
    elsif ( $fun eq 'echo') { $fun = sub{$_[2]} }
  }
  my $lc1 = ($lc eq '') ? $lc : "$lc?"; #!!!
  $self->add_hook('regex', qr/$lc1<$tag>\n?((?:.|\n)*?)$lc1<\/$tag>\n?/, $fun);
  $self->add_hook('regex', qr/$lc$tag:(.*\n)/, $fun);
}

sub ignore_outer {
  my $self = shift;
  if (ref($self) ne 'Text::Starfish')
  { unshift @_, $self; $self = $::Star; }
  my $newignoreouter = 1;
  $newignoreouter = $_[1] if $#_ > 0;
  $self->{IgnoreOuter} = $newignoreouter;
}

sub set_out_delimiters {
  my $self = shift;
  if (ref($self) ne 'Text::Starfish')
  { unshift @_, $self; $self = $::Star; }
  _croak("OutDelimiters must be array of 4 elements:(@_)") if scalar(@_)!=4;
  $self->{OutDelimiters} = [ $_[0], $_[1], $_[2], $_[3] ]; }

# eg: add_hook('string','somestring','replacement')
# add_hook('be', '<?new', '!'.'>');
sub add_hook { #!!! adding hooks
  my $self = shift;
  if (ref($self) ne 'Text::Starfish')
  { unshift @_, $self; $self = $::Star; }

  my $ht = shift;
  my $hooks = $self->{hook}; my $hook = { ht=>$ht };
  if ($ht eq 'string') {
    my $s=shift; my $replace = shift;
    $hook->{s} = $s; $hook->{evf_const} = $replace;
    push @{$hooks}, $hook;
  } elsif ($ht eq 'be') {
    my $b = shift; my $e = shift; my $f='default';
    if ($#_>-1) { $f = shift }
    $hook->{begin} = $b; $hook->{end} = $e;
    if ($f eq 'default') { $hook->{f} = \&_evaluate;
      push @{$hooks}, $hook; return;
    } elsif ($f eq 'ignore') { $hook->{f} = \&eval_ignore;
      push @{$hooks}, $hook; return;
    } elsif ($f eq 'echo') { $hook->{f} = \&eval_echo;
      push @{$hooks}, $hook; return;
    } elsif (ref($f) eq 'CODE') {
      $hook->{f} = sub { local $_; my $self=shift;
			 my $p=shift; $_=shift; my $s=shift;
			 &$f($p,$_,$s);
			 if ($self->{REPLACE}) { return $_ }
			 return "$p$_$s";
		       };
      push @{$hooks}, $hook; return;
    } else {
      $hook->{ht} = '';
      eval("\$hook->{f} = sub {\n".
      	   "local \$_;\n".
      	   "my \$self = shift;\n".
      	   "my \$p = shift; \$_ = shift; my \$s = shift;\n".
      	   "$f;\n".
      	   'if ($self->{REPLACE}) { return $_ }'."\n".
      	   "return \"\$p\$_\$s\"; };");
      _croak("add_hook error:$@") if $@;
      push @{$hooks}, $hook; return;
    }
  } elsif ($ht eq 'regex') {
    my $regex=shift; my $replace = shift;
    $hook->{regex} = $regex;
    if (ref($replace) eq '' && $replace eq 'comment')
    { $hook->{replace} = \&repl_comment }
    elsif (ref($replace) eq 'CODE')
    { $hook->{replace} = $replace }
    else { _croak("add_hook, undefined regex format input ".
		  "(TODO?): ref regex(".ref($regex).
		  "), ref replace(".ref($replace).")" ) }
    push @{$hooks}, $hook;
  } elsif ($ht eq 'ht:re2') {
    my $regex=shift; my $replace=shift;
    die unless ref($replace) eq 'CODE';
    $hook->{regex} = $regex; $hook->{replace} = $replace;
    push @{$hooks}, $hook;
  } else { _croak("add_hook error, unknown hook type `$ht'") }
}

# addHook is deprecated.  Use add_hook, which contains the hook type
# as the second argument, after $self.
sub addHook {
  my $self = shift;
  if ($#_ == 2) {
    $self->add_hook('be', @_); return;
  } elsif ($#_ == 1 and ref($_[0]) eq 'Regexp') {
    my $regex=shift; my $replace = shift;
    $self->add_hook('regex', $regex, $replace); return;
  } else { _croak("addHook parameter error") }}

sub rm_hook {
  my $self = shift;
  if (ref($self) ne 'Text::Starfish')
  { unshift @_, $self; $self = $::Star; }

  my $ht = shift; # hook type: be (begin-end)
  if ($ht eq 'be') {
    my $b=shift; my $e=shift;
    my @Hooks = @{ $self->{hook} }; my @Hooks1;
    foreach my $h (@Hooks) {
      if ($h->{begin} eq $b and $h->{end} eq $e) {}
      else { push @Hooks1, $h }
    }
    $self->{hook} = \@Hooks1;
  } else {
    _croak("rm_hook not implemented for type ht=($ht)") }
}

# rmHook to be deprecated.  Needs to be replaced with rm_hook
sub rmHook {
  my $self = shift; my $p = shift; my $s = shift;
  $self->rm_hook('be', $p, $s); return; }

sub rmAllHooks { my $self = shift; $self->{hook} = []; }

sub resetHooks { my $self = shift; $self->rmAllHooks(); $self->set_style(); }

sub add_final {
  my $self = shift;
  my $f = shift; die "$f not a function" unless ref($f) eq 'CODE';
  if (!defined($self->{Final})) { $self->{Final} = [] }
  push @{ $self->{Final} }, $f;
}

sub defineMacros {
    my $self = shift;

    return if $self->{CurrentLoop} > 1;
    $self->{Loops} = 2 if $self->{Loops} < 2;
    $self->{MprefDefine} = '//define ';
    $self->{MsufDefine} = "//enddefine\n";
    $self->{MprefExpand} = '//expand ';
    $self->{MsufExpand} = "\n";
    $self->{MacroKey}->{'expand'}   = '//m!expand ';
    $self->{MacroKey}->{'/expand'} = "\n";
    $self->{MacroKey}->{'expanded'}  = '//m!expanded ';
    $self->{MacroKey}->{'/expanded'} = "//m!end\n";
    $self->{MpreffExpand} = '//fexpand ';
    $self->{MsuffExpand} = "\n";
    $self->{MacroKey}->{'fexpand'}   = '//m!fexpand ';
    $self->{MacroKey}->{'/fexpand'} = "\n";
    $self->{MprefExpanded} = '//expanded ';
    $self->{MsufExpanded} = "//endexpanded\n";
    $self->{MpreffExpanded} = '//fexpanded ';
    $self->{MsuffExpanded} = "//endexpanded\n";
    $self->{MacroKey}->{'fexpanded'}  = '//m!fexpanded ';
    $self->{MacroKey}->{'/fexpanded'} = "//m!end\n";
    $self->{MprefAuxDefine}='//auxdefine ';
    $self->{MsufAuxDefine}="//endauxdefine\n";
    $self->{MacroKey}->{'auxdefine'}='//m!auxdefine ';
    $self->{MacroKey}->{'/auxdefine'}="//m!endauxdefine\n";
    $self->{MacroKey}->{'define'} = '//m!define ';
    $self->{MacroKey}->{'/define'} = "//m!end\n";
    $self->{MacroKey}->{'defe'} = '//m!defe ';
    $self->{MacroKey}->{'/defe'} = "//m!end\n";
    $self->{MacroKey}->{'newdefe'} = '//m!newdefe ';
    $self->{MacroKey}->{'/newdefe'} = "//m!end\n";
    push @{$self->{hook}}, #!!!
    {begin=>$self->{MprefDefine},    end=>$self->{MsufDefine}, f=>\&define},
    {begin=>$self->{MprefExpand},    end=>$self->{MsufExpand}, f=>\&expand},
    {begin=>$self->{MpreffExpand},   end=>$self->{MsuffExpand}, f=>\&fexpand},
    {begin=>$self->{MprefExpanded},  end=>$self->{MsufExpanded}, f=>\&expanded},
    {begin=>$self->{MpreffExpanded},
     end=>$self->{MsuffExpanded},f=>\&fexpanded},
    {begin=>$self->{MprefAuxDefine},
      end=>$self->{MsufAuxDefine},f=>\&auxDefine},
    {begin=>$self->{MacroKey}->{'auxdefine'},
      end=>$self->{MacroKey}->{'/auxdefine'},f=>\&MCauxdefine},
    {begin=>$self->{MacroKey}->{'define'},
      end=>$self->{MacroKey}->{'/define'},  f=>\&MCdefine},
    {begin=>$self->{MacroKey}->{'expand'},
      end=>$self->{MacroKey}->{'/expand'},  f=>\&MCexpand},
    {begin=>$self->{MacroKey}->{'fexpand'},
      end=>$self->{MacroKey}->{'/fexpand'}, f=>\&MCfexpand},
    {begin=>$self->{MacroKey}->{'expanded'},
      end=>$self->{MacroKey}->{'/expanded'},f=>\&MCexpanded},
    {begin=>$self->{MacroKey}->{'fexpanded'},
      end=>$self->{MacroKey}->{'/fexpanded'},f=>\&MCfexpanded},
    {begin=>$self->{MacroKey}->{'defe'},
      end=>$self->{MacroKey}->{'/defe'},    f=>\&MCdefe},
    {begin=>$self->{MacroKey}->{'newdefe'},
      end=>$self->{MacroKey}->{'/newdefe'}, f=>\&MCnewdefe};
    $self->{macrosdefined} = 1;
}

sub getmakefilelist ($$) {
    my $f = getfile($_[0]); shift;
    my $l = shift;
    $f =~ /\b$l=(.*(?:(?<=\\)\n.*)*)/ or
	die "starfish:getmakefilelist:no list:$l";
    $f=$1; $f=~s/\\\n/ /g;
    $f =~ s/^\s+//; $f =~ s/\s+$//;
    return split(/\s+/, $f);
}

sub echo(@) { $::O .= join('', @_) }

# used in LaTeX mode to include verbatim textual files
sub get_verbatim_file {
    my $f = shift;
    return "\\begin{verbatim}\n".
	   untabify(scalar(getfile($f))).
	   "\\end{verbatim}\n";
}

sub untabify {
    local $_ = shift;
    my ($r, $l);
    while (/[\t\n]/) {
	if ($& eq "\n") { $r.="$l$`\n"; $l=''; $_ = $'; }
	else {
	    $l .= $`;
	    $l .= ' ' x (8 - (length($l) & 7));
	    $_ = $';
	}
    }
    return $r.$l.$_;
}

sub getfile($) {
    my $f = shift;
    local *F;
    open(F, "<$f") or die "starfish:getfile:cannot open $f:$!";
    my @r = <F>;
    close(F);
    return wantarray ? @r : join ('', @r);
}

sub putfile($@) {
    my $f = shift;
    local *F;
    open(F, ">$f") or die "starfish:putfile:cannot open $f:$!";
    print F '' unless @_;
    while (@_) { print F shift(@_) }
    close(F);
}

sub appendfile($@) {
    my $f = shift;
    local *F;
    open(F, ">>$f") or die "starfish:appendfile:cannot open $f:$!";
    print F '' unless @_;
    while (@_) { print F shift(@_) }
    close(F);
}

sub htmlquote($) {
    local $_ = shift;
    s/&/&amp;/g;
    s/</&lt;/g;
    s/\"/&quot;/g;
    return $_;
}

sub read_records($ ) {
  my $arg = shift;
  if ($arg =~ /^file=/) {
    my $f = $'; local *F; open(F, $f) or croak "cannot open $f:$!";
    $arg = join('', <F>);
    close(F);
  }

  my $db = [];
  while ($arg) {
    if ($arg =~ /^([ \t\r]*(#.*)?\n)+/) { $arg = $'; }
    last if $arg eq ''; my $record;
    if ($arg =~ /([ \t\r]*\n){2,}/) { $record = "$`\n"; $arg = $'; }
    else { $record = $arg; $arg = ''; }
    my $r = {}; my $recordsave = $record;
    while ($record) {
      if ($record =~ /^[ \t]*#.*\n/) { $record=$'; next; } # allow
                                                   # comments in records
      $record =~ /^[ \t]*([^\n:]*?)[ \t]*:/ or
	croak "db8: no attribute in record: ($recordsave)";
      my $k = $1; $record = $'; my $v;
      croak "empty key in ($recordsave)" if $k eq '';
      while (1) {		# .................... line continuation
	if ($record =~ /^(.*?)\\(\r?\n)/) { $v .= $1.$2; $record = $'; }
	elsif ($record =~ /^.*?\r?\n[ \t]/) { $v .= $&; $record = $'; }
	elsif ($record =~ /^(.*?)\r?\n/) { $v .= $1; $record = $'; last; }
	else { $v .= $record; $record = ''; last }
      }
      if (exists($r->{$k})) {
	my $c = 0;
	while (exists($r->{"$k-$c"})) { ++$c }
	$k = "$k-$c";
      }
      $r->{$k} = $v;
      }
    push @{ $db }, $r;
  }
  return wantarray ? @{$db} : $db;
}

sub current_year { return POSIX::strftime("%Y", localtime(time)) }

sub last_update() {
    my $self = @_ ? shift : $::Star;
    if ($self->{Loops} < 2) { $self->{Loops} = 2 }
    return POSIX::strftime("%d-%b-%Y", localtime($self->{LastUpdateTime}));
}

sub file_modification_time() {
    my $self = @_ ? shift : $::Star;
    return (stat $self->{INFILE})[9];
}

sub file_modification_date() {
    my $self = @_ ? shift : $::Star;

    my $t = $self->file_modification_time();
    my @a = localtime($t); $a[5] += 1900;
    return qw/January February March April May June July
    	      August September October November December/
		  [$a[4]]." $a[3], $a[5]";
}

sub read_starfish_conf() {
    return unless -e "starfish.conf";
    my @dirs = ( '.' );
    while ( -e "$dirs[0]/../starfish.conf" )
    { unshift @dirs, "$dirs[0]/.." }

    my $currdir = cwd();
    foreach my $d (@dirs) {
	chdir $d or die "cannot chdir to $d";
	package main;
	require "$currdir/$d/starfish.conf";
	package Text::Starfish;
	chdir $currdir or die "cannot chdir to $currdir";
    }
}

sub _croak {
    my $m = shift;
    require Carp;
    Carp::croak($m);
}

# used in makefile mode
#kw:makefile
sub make_add_dirs_to_generate_if_needed {
  for my $d (@_) {
    next if grep { $_ eq $d } @DirGenerateIfNeeded;
    push @DirGenerateIfNeeded, $d;
  } }
sub make_gen_dirs_to_generate {
  foreach my $d (@DirGenerateIfNeeded) {
    echo "$d:; mkdir -p \$\@\n" } }

1;

__END__
# Documentation
=pod

=head1 NAME

Text::Starfish.pm and starfish - Perl-based System for Preprocessing and
      Text-Embedded Programming


=head1 SYNOPSIS

B<starfish> S<[ B<-o=>I<outputfile> ]> S<[ B<-e=>I<initialcode> ]>
        S<[ B<-replace> ]> S<[ B<-mode=>I<mode> ]> S<I<files>...>

where I<files> usually contain some Perl code, delimited by C<E<lt>?> and
C<!E<gt>>.  Use function C<echo> to produce output to be inserted into the file.

=head1 DESCRIPTION

Starfish is a system for Perl-based preprocessing and text-embedded
programming, based on a universal approach applicable to many
different text styles.  You can read the documentation contained in
the file C<report.pdf> for an introduction.  For an initial
understanding about how Starfish works, you can think of Perl code
being inserted in arbitary text between C<E<lt>?> and C<!E<gt>>
delimiters, which can be executed in a similar way as PHP code in an
HTML file.  Some similar projects exist and some of them are listed in
L<"SEE ALSO">.  Starfish has been unique in several ways.  One
important difference between C<starfish> and similar programs
(e.g., PHP) is that the output does not necessarily replace the code,
but it is appended to the code by default.

The package contains two main files: a module file (Starfish.pm) and a
small script (starfish) that provides a command-line interface to the
module.  The options for the script are described in subsection
"L<starfish_cmd list of file names and options>".

=head1 EXAMPLES

=head2 A simple example

Let us have a plain file named C<example.txt> with the following content:

     <? echo "Hello world!" !>

In the command line, run the command:

     starfish example.txt

If we open the file C<example.txt>, the content will be:

     <? echo "Hello world!" !>#+
     Hello world!#-

The same effect would be obtained with the code C<$O = "Hello world!">.
This way of updating the file is called the "update" mode of Starfish and it
is the default mode.  The "replace" mode can be used, but then we should
have a different output file, as in the following command:

  starfish -replace -o=example-out.txt example.txt

and the content of the file C<example-out.txt> would now be:

  Hello world!

The module parameters can be changed, and their default values vary according
to the text style.  THese parameters are described in the description of the
C<set_style> method.

=head2 HTML Examples

=head3 Example 1

If we have an HTML file, e.g., C<7.html> with the following
content:

  <HEAD>
  <BODY>
  <!--<? $O="This code should be replaced by this." !>-->
  </BODY>

then after running the command

  starfish -replace -o=7out.html 7.html

the file C<7out.html> will contain:

  <HEAD>
  <BODY>
  This code should be replaced by this.
  </BODY>

The same effect would be obtained with the following line:

  <!--<? echo "This code should be replaced by this." !>-->

=head3 Output file permissions

The permissions of the output file will not be changed.  But if it
does not exist, then:

  starfish -replace -o=7out.html -mode=0644 7.html

makes sure it has all-readable permission.

=head3 Example 2

Input file C<21.html>:

  <!--<? use CGI qw/:standard/;
         echo comment('AUTOMATICALLY GENERATED - DO NOT EDIT');
  !>-->
  <HTML><HEAD>
  <TITLE>Some title</TITLE>
  </HEAD>
  <BODY>
  <!--<? echo "Put this." !>-->
  </BODY>
  </HTML>

Output:

  <!-- AUTOMATICALLY GENERATED - DO NOT EDIT -->
  <HTML><HEAD>
  <TITLE>Some title</TITLE>
  </HEAD>
  <BODY>
  Put this.
  </BODY>
  </HTML>

=head2 Example from a Makefile
 
  LIST=first second third\
   fourth fifth

  <? echo join "\n", getmakefilelist $Star->{INFILE}, 'LIST', "\n" !>#+
  first
  second
  third
  fourth
  fifth
  #-

Beside $O, $Star is another predefined variable: It refers to the
Starfish object currently processing the text.

=head2 TeX and LaTeX Examples

=head3 Simple TeX or LaTeX Example

Generating text with a variable replacement:

  %<?echo "
  % When we split the probability reserved for unseen characters equally
  % among the remaining $UnseenNum characters, we obtain the final estimated
  % probabilities:
  %"!>

=head3 Example from a TeX file

 % <? $Star->Style('TeX') !>

 % For version 1 of a document
 % <? #add_hook('be',"\n%Begin1","\n%End1",'s/\n%+/\n/g');
 %    #add_hook('be',"\n%Begin2","\n%End2",'s/\n%*/\n%/g');
 %    #For version 2
 %    add_hook('be',"\n%Begin1","\n%End1",'s/\n%*/\n%/g');
 %    add_hook('be',"\n%Begin2","\n%End2",'s/\n%+/\n/g');
 % !>

 %Begin1
 %Document 1
 %End1

 %Begin2
 Document 2
 %End2

=head3 LaTeX Example with Final Routine used for Slides

  % -*- compile-command: "make 01s 01"; -*-
  %<? ##read_starfish_conf();
  %  $TexTarget = 'slides';
  %  sfish_add_tag('sl,l', 'echo');
  %  sfish_add_tag('slide', 'echo');
  %  sfish_ignore_outer;
  %  $Star->add_final( sub {
  %    my $r = shift;
  %    $r =~ s/^% -\*- compile-command.*\n//;
  %    $r.= "\\end{document}\n";
  %    return $r;
  %  } );
  % !>

  \section{Course Introduction}

  Not in slide.

  %slide:In slide.

  %<sl,l>
  In slides and lectures.
  %</sl,l>

=head2 Example with Test/Release versions (Java)

Suppose you have a stanalone java file p.java, and you want to have
two versions:

  p_t.java -- for complete code with all kinds of testing code, and
  p.java -- clean release version.

Solution:

Copy p.java to p_t.java and modify p_t.java to be like:

  /** Some Java file.  */

  //<? $O = defined($Release) ?
  // "public class p {\n" :
  // "public class p_t {\n";
  //!>//+
  public class p_t {
  //-

    public static int main(String[] args) {

      //<? $O = "    ".(defined $Release ?
      //qq[System.out.println("Test version");] :
      //qq[System.out.println("Release version");]);
      //!>//+
      System.out.println("Release version");//-

      return 0;
    }
  }

In Makefile, add lines for updating p_t.java, and generating p.java
(readonly, so that you do not modify it accidentally):

  p.java: p_t.java
        starfish -o=$@ -e='$$Release=1' -mode=0400 $<
  tmp.ind: p_t.java
        starfish $<
        touch tmp.ind

=head2 Command-line Examples

The following are the reference examples.  For further information, please
lookup the explanations of the command-line options and arguments.

B<starfish> -mode=0400 -replace -o=I<paper.tex> -mode=0400 I<paper.tex.sfish>

In the above line, Starfish is used on top of a TeX/LaTeX file.  The Starfish
is separated from the .tex file to keep the source clean.  However, a user in
this situation may by mistake start editing the paper.tex file, so we set
the output file mode to 0400 to prevent this accidental editing.

=head2 Macros

I<Note:> This is a quite old part of Starfish and needs a revision.
Macros are a form of code folding (related terms: holophrasting,
ellusion(?)), expressed in the Starfish framework.

Starfish includes a set of macro features in an experimental phase.
There are two modes, hidden macros and not hidden, which are indicated
using variable $Star->{HideMacros}, e.g.:

  starfish -e='$Star->{HideMacros}=1' *.sfish
  starfish *.sfish

Macros are activated with:

  <? $Star->defineMacros() !>

In Java mode, a macro can be defined in this way:

  //m!define macro name
  ...
  //m!end

After //m!end, a newline is mandatory.
After running Starfish, the definition will disapear in this place and
it will be appended as an auxdefine at the end of file.

In the following way, it can be defined and expanded in the same place:

  //m!defe macro name
  ...
  //m!end

A macro is expanded by:

  //m!expand macro name

When macro is expanded it looks like this:

  //m!expanded macro name
  ...
  //m!end

Macro is expanded even in hidden mode by:

  //m!fexpand macro name

and then it is expanded into:

  //m!fexpanded macro name
  ...
  //m!end

Hidden macros are put at the end of file in this way:

  //auxdefine macro name
  ...
  //endauxdefine

Old macro definition can be overriden by:

  //m!newdefe macro name
  ...
  //m!end

=head1 PREDEFINED VARIABLES AND FIELDS

=head2 $O

After executing a snippet, the contents of this variable represent the
snippet output.

=head2 $Star

More precisely, it is $::Star.  $Star is the Starfish object executing
the current code snipet (this).  There can be a more such objects
active at a time, due to executing Starfish from a starfish snippet.
The name is introduced into the main namespace, which might be a
questionable decision.

=head2 $Star->{Final}

If defined, it should be an array of CODE references, which are applied as
functions on the final output before writing it out.  These are used as final
routines, typically to add or remove some of the first lines or finals lines.
Each function takes input as a parameter and returns it after processing.
The variable should accessed using the method C<add_final>.

=head2 $Star->{INFILE}

Name of the current input file.

=head2 $Star->{Loops}

Controls the number of iterations.  The default value is 1, but we may
want to repeat starfishing the text several times, or even until a
fix-point is reached.  For example, by setting the number of Loops to
be at least 2, as in:

    $Star->{Loops} = 2 if $Star->{Loops}<2;

we require Starfish to proces the input in at least two iterations.

=head2 $Star->{Out}

Output content of the current processing unit.  For example, to use
#-style line comments in the replace Starfish mode, one can make a
final substitution in an HTML file:

 <!--<? $Star->{Out} =~ s/^#.*\n//mg; !>-->

It is important to have in mind that the contents of this variable is
the output processed so far, so any final output processing should be
done in a snippet where no new output is produced.

=head2 $Star->{OUTFILE}

If option C<-o=*> is used, then this variable contains the name of the
specified output file.

=head1 METHODS

=head2 Text::Starfish->new(options)

The method for creation of a new Starfish object.  If we are already
processing within a Starfish object, we may use a shorter variant
$Star->new().

The options, given as arguments, are a list of strings, which may
include the following:

C<-infile=*> Specifies the name of the input file (field INFILE).
   The file will not be read.

C<-copyhooks> Copies hooks from the Star object (C<$::Star>).  This
    option is also available in C<loadinclude>, C<getinclude>, and
    C<include>, from which it is passed to C<new>.  It causes the new
    object to have similar properties as the current Star object.  It
    could be generalized to include any specified object, or to use
    the prototype object that is given to the constructor, but there
    does not seem to be need for this generalization.  More precisely,
    C<-copyhooks> copies the fields: C<Style>, C<CodePreparation>,
    C<LineComment>, C<IgnoreOuter>, and per-component copies
    the array C<hook>.

=head2 $o->add_final($func_ref)

Adds the function referred to by C<$func_ref> to the list of functions to be
executed on the output at the end of processing.  See also the parameter
C<$Star-E<gt>{Final}>.

=head2 $o->add_tag($tag, $action)

Normally used by C<sfish_add_tag> by translating the call to
C<$Star-E<gt>add_tag($tag, $action)>.  Examples:

  $Star->add_tag('slide', 'ignore');
  $Star->add_tag('slide', 'echo');

See C<sfish_add_tag> for a few more details.

=head2 $o->add_hook($ht,...) -- (and function add_hook)

Adds a new hook.  The first argument is the hook type, which is a
string.  If it is used as a function, it will run on the C<$::Star> object.
The following is the list of hook types with descriptions:

=over 5

=item string, I<somestring>, I<replacementstring>

A simple hook to replace a string with another string.  In the update mode,
we must take care that the string to be replaced is commented out if needed.
For example, after the following embedded code:

  <?starfish
  add_hook('string', '<code>App::Utils</code>',
    '<a href="https://metacpan.org/pod/App-Utils" target="_blank">'.
    '<code>App::Utils</code></a>'); ?>

any occurence of C<E<lt>codeE<gt>App::UtilsE<lt>/codeE<gt>> is replaced with:

  <a href="https://metacpan.org/pod/App-Utils" target="_blank">
  <code>App::Utils</code></a>

=item be, I<prefix>, I<suffix>

Adding a hook with new prefix (begin delimiter) and suffix (end delimiter).
The following example replaces the default hook C<E<lt>?...!E<gt>> with
a new one C<E<lt>?new ...!E<gt>>:

  rm_hook('be', '<?', '!'.'>'); # remove default hook (notice that we avoid
                                # literal ending delimiter '!>' in order
                                # not to be confused with default suffix
  add_hook('be', '<?new ', '!'.'>'); # adding a new hook

=item regex, I<regex>, I<replace>

The hook type C<regex> is followed by a regular expression and a
replace argument.  Whenever a regular expression is matched in text,
it is ``starfished'' according to the argument replace.  If the
argument replace is the string ``C<comment>'', it is treated as the
comment.  If the argument replace is code, it is used as the
evaluation code.  For example, the following source in an HTML file:

  <!--<? $Star->add_hook('regex', qr/^.section:(\w+)\s+(.*)/,
  sub { $_="<a name\"$_[2]\"><h3>$_[3]</h3</a>" }) !>-->

  line before
  .section:overview Document Overview
  line after

will produce the following output, in the replace mode:

  line before
  <a name"overview"><h3>Document Overview</h3</a>
  line after

=item ht:re2, I<regex>, I<replace>

The hook type C<ht:re2> is a special type used for Python and Makefile styles
in order to capture indentation, which needs to be maintained in the output.
It is regular expression based.

=back

=head2 $o->addHook -- deprecated, should use add_hook

This method is deprecated.  It will be gradually replaced with
add_hook, which is better defined since it includes hook type.

Adds a new hook.  The method can take two or three parameters:

 ($prefix, $suffix, $evaluator)

or

 ($regex, $replacement)

In the case of three parameters C<($prefix, $suffix, $evaluator)>,
the parameter $prefix is the starting delimiter, $suffix is the ending
delimiter, and $evaluator is the evaluator.  The parameters $prefix
and $suffix can either be strings, which are matched exactly, or
regular expressions.  An empty ending delimiter will match the end of
input.  The evaluator can be provided in the following ways:

=over 5

=item special string 'default'

in which case the default Starfish evaluator is used,

=item special strings 'ignore' and 'echo'

'ignore' ignores the hook and produces no echo, 'echo' simply echos
    the contests between the delimiters.

=item other strings

are interpreted as code which is embedded in an
    evaluator by providing a local $_, $self which is the current
    Starfish object, $p - the prefix, and $s the suffix.
    After executing the code $p.$_.$s is returned, unless in the
    replacement mode, in which $_ is returned.

=item code reference (sub {...})

is interpreted as code which is embedded in an evaluator.  The local 
$_ provides the captured string.  Three arguments are also provided to
the code: $p - the prefix, $_, and $s - the suffix.
The result is the value of $_.

=back

For the format with two parameters, C<($regex, $replacement)>,
currently in this mode addHook understands replacement 'comment' and
code reference (e.g., sub { ... }).  The replacement 'comment' will
repeat the token in the non-replace mode, and remove it in the replace
mode; e.i., equivalent to no echo.  The regular expression is matched in
the multi-line mode, so ^ and $ can be used to match beginning and
ending of a line.  (Caveat: Due to the way how scanner works,
beginning of a line starts after the end of previously matched token.)

Example:

 $Star->addHook(qr/^#.*\n/, 'comment');

=head2 $o->ignore_outer()

Sets the mode for ignoring the outer text in the replace mode.  The function
C<sfish_ignore_outer> does the same on the default object C<Star>.
If an argument is given, it is used to set the mode, so as a consequence
the mode can be turned off by giving the argument ''.

=head2 $o->last_update() 

Or just last_update(), returns the date of the last update of the
output.

=head2 $o->process_files(@args)

Similar to the function starfish_cmd, but it expects already built
Starfish object with properly set options.  Actually, starfish_cmd
calls this method after creating the object and returns the object.

=head2 $o->rmHook($p,$s) -- deprecated, should use rm_hook

Removes a hook specified by the starting delimiter $p, and the ending
delimiter $s.

=head2 $o->rm_hook($ht,...) -- and function rm_hook

Removes a hook. Example:

 rm_hook('be', '<?', '!>');  # removes all hooks with give begin and end

=head2 $o->rmAllHooks()

Removes all hooks.  If no hooks are added, then after exiting the
current snippet it will not be possible to detect another snippet
later.  A typical usage could be as follows:

    $Star->rmAllHooks();
    $Star->add_hook('be', '<?starfish ','?>', 'default');

=head2 $o->setStyle($s) -- deprecated, shoud use C<set_style>

Deprecated method.  The method or function C<set_style> should be used.

=head2 set_style method or function

Sets a particular style of the source file.  If used as function, the object
C<$::Star> is used as the "self" object.  Currently implemented options are:
html, java, makefile, perl, ps, python, and tex (same as latex, 
TeX).  If the parameter $s is not given, the stile given in 
C<$o->{STYLE}> will be used if defined, otherwise it will be guessed from
the file name in C<$o->{INFILE}>.  If it cannot be correctly guessed, it
will be the Perl style.

Setting a style can have various side effects, but it typically
involves setting the following variables:

 $o->{Style}            # style string id
 $o->{CodePreparation}  # function to clean the code before running
 $o->{LineComment}      # string starting a line comment
 $o->{OutDelimiters}    # array ref with four elements: $b1, $b2 for
                        # starting output delimiter, and $e1, $e2 for
                        # the ending output delimiter; $b1 and $e1
                        # must not end with a digit, and $b2 and $e2
                        # must not start with a digit
 $o->{IgnoreOuter}      # boolean variable to ignore outer text, false
                        # by default
 $o->{hook}             # array ref, list of hooks

=head1 PREDEFINED FUNCTIONS

=head2 include( I<filename and options> ) -- starfish a file and echo

Reads, starfishes the file specified by file name, and echos the
contents.  Similar to PHP include.  Uses getinclude function.

=head2 getinclude( I<filename and options> ) -- starfish a file and return

Reads, starfishes the file specified by file name, and returns the
contents (see also include to echo the content implicitly).
By default, the program will not break if the file does not exist.
The option -noreplace will starfish file in a non-replace mode.
The default mode is replace and that is usually the mode that is
needed in includes (non-replace may lead to a suprising behaviour).
The option -require will cause program to croak if the file does not
exist.  It is similar to the PHP function require.  A special function
named require is not used since C<require> is a Perl reserved word.
Another interesting option is C<-copyhooks>, for using hooks and some
other relevant properties from the Star object (C<$::Star>).  This
option is eventually passed to C<new>, so you can see the constructor
new for more details.

The code for get include is the following:

 sub getinclude($@) {
     my $sf = loadinclude(@_);
     $sf->_digest();
     return $sf->{Out};
 }

and it can be used as a useful template for using C<loadinclude>
directly.  The function C<loadinclude> creates a Starfish object, and
reads the file, however it is not digested yet, so one can modify the
object before this.

=head2 loadinclude( I<filename and options> ) -- load file and get ready to digest

The first argument is a filename.  Loadinclude will interpret the
options C<-replace>, C<-noreplace>, and C<-require>.  A Starfish
object is created by passing the file name as an C<-infile> argument,
and by passing other options as arguments.  The file is read and the
object is returned.  By default, the program will not break if the
file does not exist or is not readable, but it will return undef value
instead of an object.  See also documentation about
C<include>, C<getinclude>, and C<new>.

C<-noreplace> option will set up the Starfish object in the no-replace
mode.  The default mode is replace and that is usually the mode that
is needed in includes.  The option C<-require> will cause program to
croak if the file does not exist.  An interesting option is
C<-copyhooks>, which is documented in the C<new> method.

=head2 read_starfish_conf

This function is usually called at the begining of a starfish file, in
order to read local configuration.  it tests whethere there exists a
filed named C<starfish.conf> in the current directory.  If it does
exist, it checks for the same file in the parent directory, then
gran-parent directory, etc.  Once the process stops, is starts
executing the configuration files in the order from first ancestor
down.  For each file, it changes directory to the corresponding
directory, and requires (in Perl style) the file in the package main.

=head2 sfish_add_tag ( I<tag>, I<action> )

Used to introduce simple tags such as line tag C<%sl,l:> and
%<sl,l>...</sl,l> in TeX/LaTeX for inclusion and exclusion of text.
Example:

     sfish_add_tag('sl,l', 'echo');
     sfish_add_tag('slide', 'ignore');

and, for example, the following text is included:

     %sl,l:some text to the end of line
     %<sl,l>
     more lines of text
     %</sl,l>

and the following text is excluded:

     %slide:this line is excluded
     %<slide>
     more lines of text excluded
     %</slide>

=head2 sfish_ignore_outer()

Sets the default object C<$Star> in the mode for ignoring outer text if in
the replace mode.  If an argument is given, it is used to set the mode, so
as a consequence the mode can be turned off with C<sfish_ignore_outer('')>.

=head2 starfish_cmd I<list of file names and options>

The function C<starfish_cmd> is called by the script C<starfish> with
the C<@ARGV> list as the list of arguments.  The function can also be
used from Perl code to "starfish" a file, e.g.,

    starfish_cmd('somefile.txt', '-o=outfile', '-replace');

The arguments of the functions are provided in a similar fashion as
argument to the command line.  As a reminder, the command usage of the
script starfish is:

B<starfish> S<[ B<-o=>I<outputfile> ]> S<[ B<-e=>I<initialcode> ]>
        S<[ B<-replace> ]> S<[ B<-mode=>I<mode> ]> S<I<file>...>

The options are described below:

=over 5

=item B<-o=>I<outputfile>

specifies an output file.  By default, the input file is used as the
output file.  If the specified output file is '-', then the output is
produced to the standard output.

=item B<-e=>I<initialcode>

specifies the initial Perl code to be executed.

=item B<-replace>

will cause the embedded code to be replaced with the output.
WARNING: Normally used only with B<-o>.

=item B<-mode=>I<mode>

specifies the mode for the output file.  By default, the mode of the
source file is used (the first one if more outputs are accumulated
using B<-o>).  If an output file is specified, and the mode is
specified, then C<starfish> will set temporarily the u+w mode of the
output file in order to write to that file, if needed.

=back

Those were the options.

=head2 echo I<list>

appends all elements of the list to the special variable $0.

=head2 DATA FUNCTIONS

=head3 read_records($string)

The function reads strings and translates it into an array of records
according to DB822 (db8 for short) data format.  If the string starts
with 'file=' then the rest of the string is treated as a file name,
which contents replaces the string in further processing.  The string
is translated into a list of records (hashes) and a reference to the list
is returned.  The records are separated by empty line, and in each line
an attribute and its value are separated by the first colon (:).
A line can be continued using backslash (\) at the end of line, or by
starting the next line with a space or tab.  Ending a line with \
will replace "\\\n" with "\n" in the string, otherwise "\n[ \t]"
are kept as they are.
Lines starting with the hash sign (#) are considered comments and they
are ignored, unless they are part of a multi-line string. An example is:

  id:1
  name: J. Public
  phone: 000-111

  id:2
  etc.

If an attribute is repeated, it will be renamed to an attribute of the
form att-1, att-2, etc.

=head2 DATE AND TIME FUNCTIONS

=head3 current_year

returns the current year in string format.

=head3 file_modification_time

Returns modification time of this file (in format of Perl time).

=head3 file_modification_date

Returns modification date of this file (in format: Month DD, YYYY).

=head2 FILE FUNCTIONS

=head3 appendfile $filename, @list

appends list elements to the file.

=head3 getfile $filename

reads the contents of the file into a string or a list.

=head3 getmakefilelist($makefilename, $var)

returns a list, which is a list of words assigned to the variable C<$var>
in the makefile named C<$makefilename>; for example:

  FILE_LIST=file1 file2 file3\
    file4

  <? echo join "\n", getmakefilelist $Star->{INFILE}, 'FILE_LIST' !>

Embedded variables are not handled.

=head3 putfile $filename, @list

Opens the file C<$filename>, wries the list elements to the file, and closes
it. `C<putfile> I<filename>' will only touch the file.

=head1 STYLES

There is a set of predefined styles for different input files:
HTML (html), HTML templating style (html.sfish), TeX (tex), Java
(java), Makefile (makefile), PostScript (ps), Python (python), and
Perl (perl).

=head2 HTML Style (html)

=head2 HTML Templating Style (html.sfish)

This style is similar to the HTML style, but it is supposed to be run
in the replace mode towards a target .html file, so it allows for more
hooks.  The character C<#> (hash) at the beginning of a line denotes a
comment.

=head2 Makefile Style (makefile)

The main code hooks are C<E<lt>?> and C<E<gt>>.

Interestingly, the makefile style has similar special requirements as Python.
For example, in the following expansion:

 starfish: tmp
         starfish Makefile
         #<? if (-e "file.tex.sfish")
         #{ echo "\tstarfish -o=tmp/file.tex -replace file.tex.sfish\n" } !>#+
         starfish -o=tmp/file.tex -replace file.tex.sfish
         #-

it is convenient to have the embedded output indented in the same way as the embedded code.

=head1 STYLE SPECIFIC PREDEFINED FUNCTIONS

=head2 get_verbatim_file( I<filename> )

Specific to LaTeX mode.  Reads textual file I<filename> and returns a
string ready for inclusion in a LaTeX document.  It untabifies the
file contests for proper representation of whitespace.  The function
code is basically:

    return "\\begin{verbatim}\n".
	   untabify(scalar(getfile($f))).
	   "\\ end{verbatim}\n";

Note: There is no space betwen C<\\> and C<end{verbatim}>.

=head2 htmlquote( I<string> )

The following definition is taken from the CIPP project.

(F<http://aspn.activestate.com/ASPN/CodeDoc/CIPP/CIPP/Manual.html>,
 link does not seem to be active any more)

This command quotes the content of a variable, so that it can be used
inside a HTML option or <TEXTAREA> block without the danger of syntax
clashes. The following conversions are done in this order:

       &  =>  &amp;
       <  =>  &lt;
       "  =>  &quot;

=head1 LIMITATIONS AND BUGS

The script swallows the whole input file at once, so it may not work
on small-memory machines and with huge files.

=head1 THANKS

I'd like to thank Steve Yeago, Tony Cox, Tony Abou-Assaleh for
comments, Charles Ikeson for suggesting the include function and
other comments, and Mohammad S Anwar for corrections in Perl packaging.

=head1 AUTHORS

 2001-2020 Vlado Keselj http://web.cs.dal.ca/~vlado
           and contributing authors:
      2007 Charles Ikeson (overhaul of test.pl)

This script is provided "as is" without expressed or implied warranty.
This is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

The latest version can be found at F<http://web.cs.dal.ca/~vlado/srcperl/>.

=head1 SEE ALSO

There are several projects similar to Starfish.  Some of them are
text-embedded programming projects such as PHP with different
programming languages, and there are similar Perl-based projects.
When I was thinking about a need of a framework like this one (1998),
I have found ePerl project.  However, it was too heavy weight for my
purposes, and it did not support the "update" mode, vs. replace mode
of operation.  I learned about more projects over time and they are
included in the list below.

=over 4

=item [ePerl] ePerl

This script is somewhat similar to ePerl, about which you can read at

F<http://www.ossp.org/pkg/tool/eperl/>.  It was developed by Ralf
S. Engelshall in the period from 1996 to 1998.

=item php

F<http://www.php.net>

=item [ePerl-h] ePerl hack by David Ljung Madison

This is a Perl script simulating the ePerl functionality, but with
obviously much lower weight.  It is developed by David Ljung Madison,
and can be found at the URL: F<http://marginalhacks.com/Hacks/ePerl/>

=item [Text::Template] Perl module Text::Template by Mark Jason
  Dominus.

F<http://search.cpan.org/~mjd/Text-Template/>
Text::Template is a module with similar functionality as Starfish.
An interesting similarity is that the output variable in
Text::Template is called $OUT, compared to $O in Starfish.

=item [HTML::Mason] Perl module HTML::Mason by Jonathan Swartz, Dave
  Rolsky, and Ken Williams.

F<http://search.cpan.org/~drolsky/HTML-Mason-1.28/lib/HTML/Mason/Devel.pod>
The module HTML::Mason can also be seen as an embedded Perl system, but
it is a larger system with the design objective being a
"high-performance, dynamic web site authoring system".

=item [HTML::EP] Perl Module HTML::EP - a system for embedding Perl
  into HTML, by Jochen Wiedmann.

F<http://search.cpan.org/~jwied/HTML-EP-MSWin32/lib/HTML/EP.pod>
It seems that the module was developed in 1998-99.  Provides a good
CGI support, run-time support, session handling, a database server
interface.

=back

=cut
