use strict;
use warnings;

use Lingua::Anagrams;
use Test::More tests => 12;
use Test::Exception;

lives_ok { Lingua::Anagrams->new( [qw(a b c d)] ) } 'built vanilla anagramizer';
lives_ok { Lingua::Anagrams->new( [qw(a b c d)], limit => 10 ) }
'built anagramizer with new limit';
lives_ok {
    Lingua::Anagrams->new( [qw(a b c d)], cleaner => sub { } );
}
'built anagramizer with different cleaner';

my $ag       = Lingua::Anagrams->new( [qw(a b c ab bc ac abc)], sorted => 1 );
my @anagrams = $ag->anagrams('abc');
my @expected = ( [qw(a b c)], [qw(a bc)], [qw(ab c)], [qw(abc)], [qw(ac b)] );
is_deeply \@anagrams, \@expected, 'got expected anagrams';
$ag = Lingua::Anagrams->new( [qw(a b c ab bc ac abc)] );
@anagrams = $ag->anagrams( 'abc', sorted => 1 );
is_deeply \@anagrams, \@expected, 'got expected anagrams';
@anagrams = $ag->anagrams( 'abc', { sorted => 1 } );
is_deeply \@anagrams, \@expected, 'got expected anagrams';

my $i = $ag->iterator("abc");
my @ar;
while ( my $anagram = $i->() ) {
    push @ar, [ sort @$anagram ];
}
is_deeply [ ag_sort(@ar) ], \@expected, 'iterator returned all anagrams';

my $i1 = $ag->iterator('ab');
my $i2 = $ag->iterator('ac');
@ar = $ag->anagrams('bc');
is_deeply \@ar, [ [ 'b', 'c' ], ['bc'] ],
  'obtained correct anagrams with iterators open';
my ( @ar1, @ar2 );
while ( my $a1 = $i1->() or my $a2 = $i2->() ) {
    push @ar1, $a1 if $a1;
    push @ar2, $a2 if $a2;
}
is_deeply [ ag_sort(@ar1) ], [ [ 'a', 'b' ], ['ab'] ],
  'first iterator operated completely in parallel with other extractions';
is_deeply [ ag_sort(@ar2) ], [ [ 'a', 'c' ], ['ac'] ],
  'second iterator operated completely in parallel with other extractions';

$i = $ag->iterator( 'abc', random => 1 );
@ar = ();
while ( my $anagram = $i->() ) {
    push @ar, $anagram;
}

# there is no surefire way to test the randomness of the random iterator
is scalar(@ar), scalar(@expected),
  'got correct number of anagrams with random iterator';
$i = $ag->iterator( 'abc', random => 1, sorted => 1 );
@ar = ();
while ( my $anagram = $i->() ) {
    push @ar, $anagram;
}
is_deeply [ ag_sort(@ar) ], \@expected, 'sort parameter works for iterator';

sub ag_sort {
    sort {
        my $ordered = @$a <= @$b ? 1 : -1;
        my ( $d, $e ) = $ordered == 1 ? ( $a, $b ) : ( $b, $a );
        for ( 0 .. $#$d ) {
            my $c = $d->[$_] cmp $e->[$_];
            return $ordered * $c if $c;
        }
        -$ordered;
    } @_;
}
