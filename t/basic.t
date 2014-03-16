use strict;
use warnings;

use Lingua::Anagrams;
use Test::More tests => 4;
use Test::Exception;

lives_ok { Lingua::Anagrams->new( [qw(a b c d)] ) } 'built vanilla anagramizer';
lives_ok { Lingua::Anagrams->new( [qw(a b c d)], limit => 10 ) }
'built anagramizer with new limit';
lives_ok {
    Lingua::Anagrams->new( [qw(a b c d)], cleaner => sub { } );
}
'built anagramizer with different cleaner';

my $a        = Lingua::Anagrams->new( [qw(a b c ab bc ac abc)] );
my @anagrams = $a->anagrams('abc');
my @expected = ( [qw(a b c)], [qw(a bc)], [qw(ab c)], [qw(abc)], [qw(ac b)] );
is_deeply \@anagrams, \@expected, 'got expected anagrams';

done_testing();
