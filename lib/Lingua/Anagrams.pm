package Lingua::Anagrams;

# ABSTRACT: pure Perl anagram finder

use strict;
use warnings;

use List::MoreUtils qw(uniq);

=head1 SYNOPSIS

  use v5.10;
  use Lingua::Anagrams;
  
  open my $fh, '<', 'words.txt' or die "Aargh! $!";         # some 100,000 words
  my @words = map { ( my $w = $_ ) =~ s/\W+//g; $w } <$fh>;
  close $fh;
  
  my @enormous = grep { length($_) > 6 } @words;
  my @huge     = grep { length($_) == 6 } @words;
  my @big      = grep { length($_) == 5 } @words;
  my @medium   = grep { length($_) == 4 } @words;
  my @small    = grep { length($_) == 3 } @words;
  my @tiny     = grep { length($_) < 3 } @words;
  
  my $anagramizer = Lingua::Anagrams->new(
      [ \@enormous, \@huge, \@big, \@medium, \@small, \@tiny ],
      limit => 30 );
  
  my $t1 = time;
  my @anagrams =
    $anagramizer->anagrams( 'Ada Hyacinth Melton-Houghton', sorted => 1, min => 100 );
  my $t2 = time;
  
  say join ' ', @$_ for @anagrams;
  say '';
  say scalar(@anagrams) . ' anagrams';
  say 'it took ' . ( $t2 - $t1 ) . ' seconds';
  
  say "\nnow for a random sample\n";
  my $i = $anagramizer->iterator( 'Ada Hyacinth Melton-Houghton', random => 1 );
  say join ' ', @{ $i->() };

Giving you

  ...
  manned ohioan thatch toughly
  menial noonday thatch though
  monthly ohioan thatch unaged
  moolah nighty notched utahan
  moolah tannin though yachted
  moolah thatch toeing unhandy
  
  1582 anagrams
  it took 129 seconds
  
  now for a random sample
  
  noumenal acanthi doth thy hog

=head1 DESCRIPTION

L<Lingua::Anagrams> constructs tries out of a lists of words you give it. It then uses these
tries to find all the anagrams of a phrase you give to its C<anagrams> method. A dynamic
programming algorithm is used to accelerate the search at the cost of memory. See
C<new> for how one may modify this algorithm.

Be aware that the anagram algorithm has been golfed down pretty far to squeeze more speed out
of it. It isn't the prettiest.

=cut

# don't cache anagrams for bigger character counts than this
our $LIMIT = 20;

# some global variables to be localized
# used to limit time spent copying values
our ( $limit, $known, $trie, %cache, $cleaner, @jumps, $word_cache, @indices );

=method CLASS->new( $word_list, %params )

Construct a new anagram engine from a word list, or a list of word lists. If you provide multiple
word lists, each successive list will be understood as an augmentation of those preceding it.
If you search for the anagrams of a phrase, the algorithm will abandon one list and try the
next if it is unable to find sufficient anagrams with the current list. You can use cascading
word lists like this to find interesting anagrams of long phrases as well as short ones in
a reasonable amount of time. If on the other hand you use only one comprehensive list you will
find that long phrases have many millions of anagrams the calculation of which take vast amounts
of memory and time. In particular you will want to limit the number of short words in the
earlier lists as these multiply the possible anagrams much more quickly.

The optional construction parameters may be provided either as a list of key-value pairs or
as a hash reference. The understood parameters are:

=over 4

=item limit

The character count limit used by the dynamic programming algorithm to throttle memory
consumption somewhat. If you wish to find the anagrams of a very long phrase you may
find the caching in the dynamic programming algorithm consumes too much memory. Set this
limit lower to protect yourself from memory exhaustion (and slow things down).

The default limit is set by the global C<$LIMIT> variable. It will be 20 unless you
tinker with it.

=item clean

A code reference specifying how text is to be cleaned of extraneous characters
and normalized. The default cleaning function is

  sub _clean {
      $_[0] =~ s/\W+//g;
      $_[0] = lc $_[0];
  }

Note that this function, like C<_clean>, must modify its argument directly.

=item sorted

A boolean. If true, the anagram list will be returned sorted.

=item min

The minimum number of anagrams to look for. This value is only consulted if the anagram engine
has more than one word list. If the first word list returns too few anagrams, the second is
applied. If no minimum is provided the effective minimum is one.

=back

=cut

sub new {
    my $class = shift;
    my $wl    = shift;
    die 'first parameter expected to be an array reference'
      unless ref $wl eq 'ARRAY';
    my %params = _make_opts(@_);
    $class = ref $class || $class;
    local $cleaner = $params{clean} // \&_clean;
    my @word_lists;
    if ( ref $wl->[0] eq 'ARRAY' ) {
        @word_lists = @$wl;
    }
    else {
        @word_lists = ($wl);
    }
    my ( @tries, @all_words );
    for my $words (@word_lists) {
        next unless @$words;
        die 'items in lists expected to be words' if ref $words->[0];
        $cleaner->($_) for @$words;
        my $s1 = @all_words;
        push @all_words, @$words;
        @all_words = uniq @all_words;
        next unless @all_words > $s1;
        my ( $trie, $known ) = _trieify( \@all_words );
        push @tries, [ $trie, $known ];
    }
    die 'no words' unless @tries;
    return bless {
        limit  => $params{limit}  // $LIMIT,
        sorted => $params{sorted} // 0,
        min    => $params{min},
        clean  => $cleaner,
        tries  => \@tries,
      },
      $class;
}

sub _trieify {
    my $words = shift;
    my $base  = [];
    my @known;
    my $terminal = [];
    for my $word (@$words) {
        next unless length( $word // '' );
        my @chars = map ord, split //, $word;
        _learn( \@known, \@chars );
        _add( $base, \@chars, $terminal );
    }
    return $base, \@known;
}

sub _learn {
    my ( $known, $new ) = @_;
    for my $i (@$new) {
        $known->[$i] ||= 1;
    }
}

sub _add {
    my ( $base, $chars, $terminal ) = @_;
    my $i = shift @$chars;
    if ($i) {
        my $next = $base->[$i] //= [];
        _add( $next, $chars, $terminal );
    }
    else {
        $base->[0] //= $terminal;
    }
}

# walk the trie looking for words you can make out of the current character count
sub _words_in {
    my ( $counts, $total ) = @_;
    my @words;
    my @stack = ( [ 0, $trie ] );
    while (1) {
        my ( $c, $level ) = @{ $stack[-1] };
        if ( $c == -1 || $c >= @$level ) {
            last if @stack == 1;
            pop @stack;
            ++$total;
            $c = \( $stack[-1][0] );
            ++$counts->[$$c];
            $$c = $jumps[$$c];
        }
        else {
            my $l = $level->[$c];
            if ($l) {    # trie holds corresponding node
                if ($c) {    # character
                    if ( $counts->[$c] ) {
                        push @stack, [ 0, $l ];
                        --$counts->[$c];
                        --$total;
                    }
                    else {
                        $stack[-1][0] = $jumps[$c];
                    }
                }
                else {       # terminal
                    my $w = join '',
                      map { chr( $_->[0] ) } @stack[ 0 .. $#stack - 1 ];
                    $w = $word_cache->{$w} //= scalar keys %$word_cache;
                    push @words, [ $w, [@$counts] ];
                    if ($total) {
                        $stack[-1][0] = $jumps[$c];
                    }
                    else {
                        pop @stack;
                        ++$total;
                        $c = \( $stack[-1][0] );
                        ++$counts->[$$c];
                        $$c = $jumps[$$c];
                    }
                }
            }
            else {
                $stack[-1][0] = $jumps[$c];
            }
        }
    }
    \@words;
}

=method $self->anagrams( $phrase, %opts )

Returns a list of array references, each reference containing a list of
words which together constitute an anagram of the phrase.

Options may be passed in as a list of key value pairs or as a hash reference.
The following options are supported at this time:

=over 4

=item sorted

As with the constructor option, this determines whether the anagrams are sorted
internally and with respect to each other. It overrides the constructor parameter,
which provides the default.

=item min

The minimum number of anagrams to look for. This value is only consulted if the anagram engine
has more than one word list. This overrides any value from the constructor parameter C<min>.

=item start_list

Index of first word list to try. This will be 0 by default. Set it to -1 to use only the
largest word list. The bigger the word list you start with, the smaller the words you are likely
to get in any particular anagram but also the faster you will fail when no anagrams are possible.

=back

=cut

sub anagrams {
    my $self   = shift;
    my $phrase = shift;
    my %opts   = _make_opts(@_);
    local ( $limit, $cleaner ) = @$self{qw(limit clean)};
    $cleaner->($phrase);
    return () unless length $phrase;
    my ( $sort, $min );

    if ( exists $opts{sorted} ) {
        $sort = $opts{sorted};
    }
    else {
        $sort = $self->{sorted};
    }
    if ( exists $opts{min} ) {
        $min = $opts{min};
    }
    else {
        $min = $self->{min};
    }
    my $i = $opts{start_list} // 0;
    my @pairs = @{ $self->{tries} };
    if ($i) {
        die "impossible index for start list: $i" unless defined $pairs[$i];
        $i = @pairs + $i if $i < 0;
        @pairs = @pairs[ $i .. $#pairs ];
    }
    my $counts = _counts($phrase);
    local @jumps   = _jumps($counts);
    local @indices = _indices($counts);
    my @anagrams;
    local $word_cache = {};
    for my $pair (@pairs) {
        local ( $trie, $known ) = @$pair;
        next unless _all_known($counts);
        local %cache = ();
        %$word_cache = ();
        @anagrams    = _anagramize($counts);
        next unless @anagrams;
        next if $min and @anagrams < $min;
        last;
    }
    my %r = reverse %$word_cache;
    @anagrams = map {
        [ map { $r{$_} } @$_ ]
    } @anagrams;
    if ($sort) {
        @anagrams = sort {
            my $ordered = @$a <= @$b ? 1 : -1;
            my ( $d, $e ) = $ordered == 1 ? ( $a, $b ) : ( $b, $a );
            for ( 0 .. $#$d ) {
                my $c = $d->[$_] cmp $e->[$_];
                return $ordered * $c if $c;
            }
            -$ordered;
        } map { [ sort @$_ ] } @anagrams;
    }
    return @anagrams;
}

sub _make_opts {
    if ( @_ == 1 ) {
        my $r = shift;
        die 'options expected to be key value pairs or a hash ref'
          unless 'HASH' eq ref $r;
        return %$r;
    }
    else {
        return @_;
    }
}

=method $self->iterator($phrase, %opts)

Generators a code reference once can use to iterate over all the anagrams
of a phrase. This iterator will be considerably slower than the C<anagrams> method
if you want to fetch all the anagrams of a phrase but considerably faster if your
phrase is large and you just want a sample of anagrams. And if your phrase is
sufficiently large that there is not sufficient memory and/or time to create the
complete anagram list, an iterator is your only option. Iterators are much more
memory efficient.

If the anagram engine holds multiple word lists, longer lists are sorted only as
necessary.

As with the other methods, the optional C<%opts> may be provided as either a list
of key-value pairs or as a hash reference. The understood options are

=over 4

=item sorted

If true, anagrams will be internally sorted, though not necessarily relative to each
other. In fact, because of how anagrams are gathered, they will tend to be returned
in sorted order unless the C<random> parameter is set to true.

=item random

If true, the anagrams are returned in relatively random order. The order is only
relatively random because it will still be the case that longer word lists are only
consulted as a last resort.

=item start_list

Index of first word list to try. This will be 0 by default. This is the same option as with
the C<anagrams> method. It is particularly useful in conjunction with the C<random> option. It
will speed up both success and failure.

=back

=cut

sub iterator {
    my $self   = shift;
    my $phrase = shift;
    my %opts   = _make_opts(@_);
    $opts{sorted} //= $self->{sorted};
    $self->{clean}->($phrase);
    my $i = $opts{start_list} // 0;
    my @pairs = @{ $self->{tries} };
    if ($i) {
        die "impossible index for start list: $i" unless defined $pairs[$i];
        $i = @pairs + $i if $i < 0;
        @pairs = @pairs[ $i .. $#pairs ];
    }
    return sub { }
      unless length $phrase;
    return _super_iterator( \@pairs, $phrase, \%opts );
}

# iterator that converts word indices back to words
sub _super_iterator {
    my ( $tries, $phrase, $opts ) = @_;
    my $counts = _counts($phrase);
    my @j      = _jumps($counts);
    my @ix     = _indices($counts);
    my $wc     = {};
    my $i      = _iterator( $tries, $counts, $opts );
    my ( %reverse_cache, %c );
    return sub {
        my $rv;
        local @jumps      = @j;
        local @indices    = @ix;
        local $word_cache = $wc;
        {
            $rv = $i->();
            return unless $rv;
            my $key = join ',', sort { $a <=> $b } @$rv;
            redo if $c{$key}++;
        }
        for my $j (@$rv) {
            if ( !$reverse_cache{$j} ) {
                %reverse_cache = reverse %$word_cache;
                last;
            }
        }
        $rv = [ map { $reverse_cache{$_} } @$rv ];
        if ( $opts->{sorted} ) {
            $rv = [ sort @$rv ];
        }
        $rv;
    };
}

# iterator that manages the trie list
sub _iterator {
    my ( $tries, $counts, $opts ) = @_;
    my $total = 0;
    $total += $_ for @$counts[@indices];
    my @t = @$tries;
    my $i;
    my $s = sub {
        my $rv;
        {
            unless ($i) {
                if (@t) {
                    my $pair = shift @t;
                    local ( $trie, $known ) = @$pair;
                    redo unless _all_known($counts);
                    my $words = _words_in( $counts, $total );
                    redo unless _worth_pursuing( $counts, $words );
                    $i = _sub_iterator( $tries, $words, $opts );
                }
                else {
                    return $rv;
                }
            }
            $rv = $i->();
            unless ($rv) {
                undef $i;
                redo;
            }
        }
        $rv;
    };
    $s;
}

# iterator that actually walks tries looking for anagrams
sub _sub_iterator {
    my ( $tries, $words, $opts ) = @_;
    my @pairs = @$words;
    return sub {
        {
            return unless @pairs;
            if ( $opts->{random} ) {
                my $i = int rand scalar @pairs;
                if ($i) {
                    my $p = $pairs[0];
                    $pairs[0] = $pairs[$i];
                    $pairs[$i] = $p;
                }
            }
            my ( $w, $s ) = @{ $pairs[0] };
            unless ( ref $s eq 'CODE' ) {
                if ( _any($s) ) {
                    $s = _iterator( $tries, $s, $opts );
                }
                else {
                    my $next = [];
                    $s = sub {
                        my $rv = $next;
                        undef $next;
                        $rv;
                    };
                }
                $pairs[0][1] = $s;
            }
            my $remainder = $s->();
            unless ($remainder) {
                shift @pairs;
                redo;
            }
            return [ $w, @$remainder ];
        }
    };
}

# all character counts decremented
sub _worth_pursuing {
    my ( $counts, $words ) = @_;

    my $c;

    # if any letter count didn't change, there's no hope
  OUTER: for my $i (@indices) {
        next unless $c = $counts->[$i];
        for (@$words) {
            next OUTER if $_->[1][$i] < $c;
        }
        return;
    }
    return 1;
}

sub _indices {
    my $counts = shift;
    my @indices;
    for my $i ( 0 .. $#$counts ) {
        push @indices, $i if $counts->[$i];
    }
    return @indices;
}

sub _jumps {
    my $counts = shift;
    my @jumps  = (0) x @$counts;
    my $j      = 0;
    while ( my $n = _next_jump( $counts, $j ) ) {
        $jumps[$j] = $n;
        $j = $n;
    }
    $jumps[-1] = -1;
    return @jumps;
}

sub _next_jump {
    my ( $counts, $j ) = @_;
    for my $i ( $j + 1 .. $#$counts ) {
        return $i if $counts->[$i];
    }
    return;
}

sub _clean {
    $_[0] =~ s/\W+//g;
    $_[0] = lc $_[0];
}

sub _all_known {
    my $counts = shift;
    return if @$counts > @$known;
    for my $i ( 0 .. $#$counts ) {
        return if $counts->[$i] && !$known->[$i];
    }
    return 1;
}

sub _counts {
    my $phrase = shift;
    $phrase =~ s/\s//g;
    my @counts;
    for my $c ( map ord, split //, $phrase ) {
        $counts[$c]++;
    }
    $_ //= 0 for @counts;
    return \@counts;
}

sub _any {
    for ( @{ $_[0] } ) {
        return 1 if $_;
    }
    '';
}

sub _anagramize {
    my $counts = shift;
    my $total  = 0;
    $total += $_ for @$counts[@indices];
    my $key;
    if ( $total <= $limit ) {
        $key = join ',', @$counts[@indices];
        my $cached = $cache{$key};
        return @$cached if $cached;
    }
    my @anagrams;
    my $words = _words_in( $counts, $total );
    if ( _all_touched( $counts, $words ) ) {
        for (@$words) {
            my ( $word, $c ) = @$_;
            if ( _any($c) ) {
                push @anagrams, [ $word, @$_ ] for _anagramize($c);
            }
            else {
                push @anagrams, [$word];
            }
        }
        my %seen;
        @anagrams = map {
            $seen{ join ' ', sort { $a <=> $b } @$_ }++
              ? ()
              : $_
        } @anagrams;
    }
    $cache{$key} = \@anagrams if $key;
    @anagrams;
}

sub _all_touched {
    my ( $counts, $words ) = @_;

    my $c;

    my ( @tallies, @good_indices );
    for (@$words) {
        my $wc = $_->[1];
        for (@indices) {
            next unless $c = $counts->[$_];
            $good_indices[$_] //= $_;
            $tallies[$_]++ if $wc->[$_] < $c;
        }
    }

    # if any letter count didn't change, there's no hope
    return unless @good_indices;
    for (@good_indices) {
        next   unless $_;
        return unless $tallies[$_];
    }

    # find the letter with the fewest possibilities
    my ( $best, $min, $n );
    for (@good_indices) {
        next unless $_;
        $n = $tallies[$_];
        if ( !$best || $n < $min ) {
            $best = $_;
            $min  = $n;
        }
    }

    # we only need consider all the branches which affected a
    # particular letter; we will find all possibilities in their
    # ramifications
    $c = $counts->[$best];
    @$words = grep { $_->[1][$best] < $c } @$words;
    return 1;
}

1;

__END__

=head1 SOME CLEVER BITS

One trick I use to speed things up is to convert all characters to integers
immediately. If you're using integers, you can treat arrays are really fast
hashes.

Another is, in the trie, to build the trie only of arrays. The character
identity is encoded in the array position, the distance from the start by depth.
So the trie contains nothing but arrays. For a little memory efficiency the
terminal symbols is always the same empty array.

The natural way to walk the trie is with recursion, but I use a stack and a loop
to speed things up.

I use a jump table to keep track of the actual characters under consideration so
when walking the trie I only consider characters that might be in anagrams.

A particular step of anagram generation consists of pulling out all words that
can be formed with the current character counts. If a particular character count
is not decremented in the formation of any word in a given step we know we've
reached a dead end and we should give up.

Similarly, if we B<do> touch every character in a particular step we can collect
all the words extracted which touch that character and descend only into the
remaining possibilities for those character counts because the other words one
might exctract are necessarily contained in the remaining character counts.

The dynamic programming bit consists of memoizing the anagram lists keyed to the
character counts so we never extract the anagrams for a particular set of counts
twice (of course, we have to calculate this key many times, which is not free).

I localize a bunch of variables on the first method call so that thereafter
these values can be treated as global. This saves a lot of copying.

After the initial method calls I use functions, which saves a lot of lookup time.

In stack operations I use push and pop in lieu of unshift and shift. The former
are more efficient, especially with short arrays.

=cut
