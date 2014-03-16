package Lingua::Anagrams;

# ABSTRACT: pure Perl anagram finder

use strict;
use warnings;

=head1 SYNOPSIS

  use Lingua::Anagrams;

  open my $fh, '<', 'wordsEn.txt' or die "Aargh! $!";
  my @words = <$fh>;
  close $fh;

  my $anagramizer = Lingua::Anagrams->new( \@words );  # NOT a good word list for this purpose

  my $t1       = time;
  my @anagrams = $anagramizer->anagrams('Find anagrams!');
  my $t2       = time;

  print join ' ', @$_ for @anagrams;
  print "\n\n";
  print scalar(@anagrams) , " anagrams\n"";
  print 'it took ' , ( $t2 - $t1 ) , " seconds\n"";
  
Giving you

  ...
  naif nm rag sad
  naif nm raga sd
  naif nm rd saga
  naif ragman sd

  20906 anagrams
  it took 3 seconds
  
=head1 DESCRIPTION

L<Lingua::Anagrams> constructs a trie out of a list of words you give it. It then uses this
trie to find all the anagrams of a phrase you give to its C<anagrams> method. A dynamic
programming algorithm is used to accelerate at the cost of memory. See C<new> for how one may
modify this algorithm.

Be aware that the anagram algorithm has been golfed down pretty far to squeeze more speed out
of it. It isn't the prettiest.

=cut

# don't cache anagrams for bigger character counts than this
our $LIMIT = 20;

# some global variables to be localized
# used to limit time spent copying values
our ( $limit, $known, $trie, $cache, $lower, $cleaner, $jumps );

=method CLASS->new( $word_list, %params )

Construct a new anagram engine from a word list. The parameters understood
by the constructor are

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

=back

=cut

sub new {
    my ( $class, $words, %params ) = @_;
    $class = ref $class || $class;
    local $cleaner = $params{clean} // \&_clean;
    my ( $trie, $known, $lowest ) = _trieify($words);
    die 'no words' unless $lowest;
    return bless {
        limit => $params{limit} // $LIMIT,
        clean => $cleaner,
        trie  => $trie,
        known => $known,
    }, $class;
}

sub _trieify {
    my $words = shift;
    my $base  = [];
    my ( @known, $lowest );
    for my $word (@$words) {
        $cleaner->($word);
        next unless length $word;
        my @chars = map ord, split //, $word;
        for my $i (@chars) {
            if ( defined $lowest ) {
                $lowest = $i if $i < $lowest;
            }
            else {
                $lowest = $i;
            }
        }
        _learn( \@known, \@chars );
        push @chars, 0;
        _add( $base, \@chars );
    }
    return $base, \@known, $lowest;
}

sub _learn {
    my ( $known, $new ) = @_;
    for my $i (@$new) {
        $known->[$i] ||= 1;
    }
}

sub _add {
    my ( $base, $chars ) = @_;
    my $i = shift @$chars;
    my $next = $base->[$i] //= [];
    _add( $next, $chars ) if $i;
}

# walk the trie looking for words you can make out of the current character count
sub _words_in {
    my ( $counts, $total ) = @_;
    my @words;
    my @stack = ( [ 0, $trie, scalar @$trie ] );
    while (1) {
        my ( $c, $level, $limit ) = @{ $stack[0] };
        if ( $c == -1 || $c >= $limit ) {
            last if @stack == 1;
            shift @stack;
            ++$total;
            ++$counts->[ $stack[0][0] ];
            $stack[0][0] = $jumps->[ $stack[0][0] ];
        }
        else {
            my $l = $level->[$c];
            if ($l) {    # trie holds corresponding node
                if ($c) {    # character
                    if ( $counts->[$c] ) {
                        unshift @stack, [ 0, $l, scalar @$l ];
                        --$counts->[$c];
                        --$total;
                    }
                    else {
                        $stack[0][0] = $jumps->[$c];
                    }
                }
                else {       # terminal
                    push @words,
                      [
                        join( '',
                            reverse map { chr( $_->[0] ) }
                              @stack[ 1 .. $#stack ] ),
                        [@$counts]
                      ];
                    if ($total) {
                        $stack[0][0] = $jumps->[$c];
                    }
                    else {
                        shift @stack;
                        ++$total;
                        ++$counts->[ $stack[0][0] ];
                        $stack[0][0] = $jumps->[ $stack[0][0] ];
                    }
                }
            }
            else {
                $stack[0][0] = $jumps->[$c];
            }
        }
    }
    @words;
}

=method $self->anagrams( $phrase )

Returns a list of array references, each reference containing a list of
words which together constitute an anagram of the phrase.

=cut

sub anagrams {
    my ( $self, $phrase ) = @_;
    local ( $trie, $known, $limit, $cleaner ) =
      @$self{qw(trie known limit clean)};
    $cleaner->($phrase);
    return () unless length $phrase;
    my $counts = _counts($phrase);
    return () unless _all_known($counts);
    local $jumps = _jumps($counts);
    my $lowest = $jumps->[0];
    local $lower = $lowest - 1;
    local $cache = {};
    return _anagramize($counts);
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
    return \@jumps;
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
    for my $v ( @{ $_[0] } ) {
        return 1 if $v;
    }
    '';
}

sub _anagramize {
    my $counts = shift;
    my $total  = 0;
    $total += $_ for @$counts;
    my $key;
    if ( $total <= $limit ) {
        $key = join ',', splice @{ [@$counts] }, $lower;
        my $cached = $cache->{$key};
        return @$cached if $cached;
    }
    my @anagrams;
    for ( _words_in( $counts, $total ) ) {
        my ( $word, $c ) = @$_;
        if ( _any($c) ) {
            push @anagrams, [ $word, @$_ ] for _anagramize($c);
        }
        else {
            push @anagrams, [$word];
        }
    }
    my %seen;
    @anagrams = map { $seen{ join ' ', sort @$_ }++ ? () : $_ } @anagrams;
    $cache->{$key} = \@anagrams if $key;
    @anagrams;
}

1;
