#!/usr/bin/perl -w

my $Has_PH;
BEGIN { 
    $Has_PH = $] < 5.009;
}

my $W;

BEGIN {
    $W = 0;
    $SIG{__WARN__} = sub {
        if ($_[0] =~ /^Hides field '.*?' in base class/) {
            $W++;
        }
        else {
            warn $_[0];
        }
    };
}

use strict;
use Test::More tests => 29;

BEGIN { use_ok('base'); }

package B1;
use fields qw(b1 b2 b3);

package B2;
use fields '_b1';
use fields qw(b1 _b2 b2);

sub new { fields::new(shift) }

package B3;
use fields qw(b4 _b5 b6 _b7);

package D1;
use base 'B1';
use fields qw(d1 d2 d3);

package D2;
use base 'B1';
use fields qw(_d1 _d2);
use fields qw(d1 d2);


package D3;
use base 'B2';
use fields qw(b1 d1 _b1 _d1);  # hide b1

package D4;
use base 'D3';
use fields qw(_d3 d3);

package M;
sub m {}

package D5;
use base qw(M B2);

# Test that multiple inheritance fails.
package D6;
eval { 'base'->import(qw(B2 M B3)); };
::like($@, qr/can't multiply inherit %FIELDS/i, 
                                        'No multiple field inheritance');

package Foo::Bar;
use base 'B1';

package Foo::Bar::Baz;
use base 'Foo::Bar';
use fields qw(foo bar baz);

# Test repeatability for when modules get reloaded.
package B1;
use fields qw(b1 b2 b3);

package D3;
use base 'B2';
use fields qw(b1 d1 _b1 _d1);  # hide b1


package main;

my %EXPECT = (
              B1 => [qw(b1 b2 b3)],
              D1 => [qw(b1 b2 b3 d1 d2 d3)],
              D2 => [qw(b1 b2 b3 _d1 _d2 d1 d2)],

              M  => [qw()],
              B2 => [qw(_b1 b1 _b2 b2)],
              D3 => [(undef,undef,undef,
                                qw(b2 b1 d1 _b1 _d1))],     # b1 is hidden
              D4 => [(undef,undef,undef,
                                qw(b2 b1 d1),undef,undef,qw(_d3 d3))],
              D5 => [undef, 'b1', undef, 'b2'],

              B3 => [qw(b4 _b5 b6 _b7)],

              'Foo::Bar'        => [qw(b1 b2 b3)],
              'Foo::Bar::Baz'   => [qw(b1 b2 b3 foo bar baz)],
             );

while(my($class, $efields) = each %EXPECT) {
    no strict 'refs';
    my %fields = %{$class.'::FIELDS'};
    my %expected_fields;
    foreach my $idx (1..@$efields) {
        my $key = $efields->[$idx-1];
        next unless $key;
        $expected_fields{$key} = $idx;
    }

    ::is_deeply(\%fields, \%expected_fields, "%FIELDS check:  $class");
}

# Did we get the appropriate amount of warnings?
is( $W, 1, 'right warnings' );


# A simple object creation and attribute access test
my B2 $obj1 = D3->new;
$obj1->{b1} = "B2";
my D3 $obj2 = $obj1;
$obj2->{b1} = "D3";

# We should get compile time failures field name typos
eval q(my D3 $obj3 = $obj2; $obj3->{notthere} = "");
if( $Has_PH ) {
    like $@, 
      qr/^No such pseudo-hash field "notthere" in variable \$obj3 of type D3/;
}
else {
    like $@, 
      qr/^Attempt to access disallowed key 'notthere' in a restricted hash/;
}

# Slices
@$obj1{"_b1", "b1"} = (17, 29);
is( $obj1->{_b1}, 17 );
is( $obj1->{b1},  29 );

@$obj1{'_b1', 'b1'} = (44,28);
is( $obj1->{_b1}, 44 );
is( $obj1->{b1},  28 );



# Break multiple inheritance with a field name clash.
package E1;
use fields qw(yo this _lah meep 42);

package E2;
use fields qw(_yo ahhh this);

eval {
    package Broken;

    # The error must occur at run time for the eval to catch it.
    require base;
    'base'->import(qw(E1 E2));
};
::like( $@, qr/Can't multiply inherit %FIELDS/i, 'Again, no multi inherit' );


package No::Version;

use vars qw($Foo);
sub VERSION { 42 }

package Test::Version;

use base qw(No::Version);
::ok( $No::Version::VERSION =~ /set by base\.pm/,          '$VERSION bug' );

# Test Inverse of $VERSION bug base.pm should not clobber existing $VERSION
package Has::Version;

BEGIN { $Has::Version::VERSION = '42' };

package Test::Version2;

use base qw(Has::Version);
::is( $Has::Version::VERSION, 42 );

package main;

our $eval1 = q{
  {
    package Eval1;
    {
      package Eval2;
      use base 'Eval1';
      $Eval2::VERSION = "1.02";
    }
    $Eval1::VERSION = "1.01";
  }
};

eval $eval1;
is( $@, '' );

is( $Eval1::VERSION, 1.01 );

is( $Eval2::VERSION, 1.02 );


eval q{use base 'reallyReAlLyNotexists'};
like( $@, qr/^Base class package "reallyReAlLyNotexists" is empty./,
                                          'base with empty package');

eval q{use base 'reallyReAlLyNotexists'};
like( $@, qr/^Base class package "reallyReAlLyNotexists" is empty./,
                                          '  still empty on 2nd load');

BEGIN { $Has::Version_0::VERSION = 0 }

package Test::Version3;

use base qw(Has::Version_0);
::is( $Has::Version_0::VERSION, 0, '$VERSION==0 preserved' );


package Test::SIGDIE;

{ 
    local $SIG{__DIE__} = sub { 
        ::fail('sigdie not caught, this test should not run') 
    };
    eval {
      'base'->import(qw(Huh::Boo));
    };

    ::like($@, qr/^Base class package "Huh::Boo" is empty/, 
         'Base class empty error message');

}
