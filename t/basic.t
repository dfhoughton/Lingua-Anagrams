use strict;
use warnings;

use Lingua::Anagrams;
use Test::More tests => 7;
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
is_deeply [ ag_sort(@ar) ], \@expected,
  'iterator returned all anagrams';

done_testing();

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
