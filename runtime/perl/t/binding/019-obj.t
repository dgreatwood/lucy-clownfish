# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

use strict;
use warnings;

use Test::More tests => 21;

package TestObj;
use base qw( Clownfish::Obj );

our $version = $Clownfish::VERSION;

package SonOfTestObj;
use base qw( TestObj );
{
    sub to_string {
        my $self = shift;
        return "STRING: " . $self->SUPER::to_string;
    }
}

package BadToString;
use base qw( Clownfish::Obj );
{
    sub to_string {}
}

package ThawTestObj;
use base qw( Clownfish::Obj );
{
    sub STORABLE_freeze {"meep"}
    sub DESTROY {}
}

package InvalidCallbackTestObj;
use base qw( Clownfish::Obj );
{
    sub to_host {}
}

package OverriddenAliasTestObj;
use base qw( Clownfish::Test::AliasTestObj );
{
    sub perl_alias {"Perl"}
}

package main;
use Storable qw( freeze thaw );
use Clownfish::Test;

ok( defined $TestObj::version,
    "Using base class should grant access to "
        . "package globals in the Clownfish:: namespace"
);

my $object = TestObj->new;
isa_ok( $object, "Clownfish::Obj",
    "Clownfish objects can be subclassed" );

SKIP: {
    skip( "Exception thrown within STORABLE hook leaks", 1 )
        if $ENV{LUCY_VALGRIND};
    my $thawed = TestObj->new;
    eval { freeze($thawed) };
    like( $@, qr/implement/i,
        "freezing an Obj throws an exception rather than segfaults" );
}

my $fake = bless {}, 'ThawTestObj';
my $frozen = freeze($fake);
eval { thaw($frozen) };
like( $@, qr/implement/,
    "thawing an Obj throws an exception rather than segfaults" );

ok( $object->is_a("Clownfish::Obj"),     "custom is_a correct" );
ok( !$object->is_a("Clownfish::Object"), "custom is_a too long" );
ok( !$object->is_a("Clownfish"),         "custom is_a substring" );
ok( !$object->is_a(""),                  "custom is_a blank" );
ok( !$object->is_a("thing"),             "custom is_a wrong" );

eval { my $another_obj = TestObj->new( kill_me_now => 1 ) };
like( $@, qr/kill_me_now/, "reject bad param" );

eval { $object->to_i64 };
like( $@, qr/Abstract method 'To_I64' not defined by TestObj/,
      "calling an abstract method throws" );

my $stringified_perl_obj = "$object";
require Clownfish::Hash;
my $hash = Clownfish::Hash->new;
$hash->store( foo => $object );
is( Clownfish::Test::refcount($object), 2, "refcount increased via C code" );
undef $object;
$object = $hash->fetch("foo");
is( "$object", $stringified_perl_obj, "same perl object as before" );

is( Clownfish::Test::refcount($object),
    2, "correct refcount after retrieval" );
undef $hash;
is( Clownfish::Test::refcount($object),
    1, "correct refcount after destruction of ref" );

$object = SonOfTestObj->new;
like( $object->to_string, qr/STRING:.*?SonOfTestObj/,
    "overridden XS bindings can be called via SUPER" );

SKIP: {
    skip( "Exception thrown within callback leaks", 2 )
        if $ENV{LUCY_VALGRIND};

    # Invoke To_String() from C space.  This test verifies that the Perl
    # bindings generated by CFC handle non-`nullable` return values correctly,
    # by ensuring that the Perl callback wrapper for to_string() checks the
    # return value and throws an exception if a Perl-space implementation
    # returns undef.
    eval { Clownfish::Test::invoke_to_string( BadToString->new ) };
    like( $@, qr/NULL/,
        "Don't allow methods without nullable return values to return NULL" );

    eval { InvalidCallbackTestObj->new; };
    like( $@, qr/Can't override CFISH_Obj_To_Host via binding/ );
}

my $alias_test = Clownfish::Test::AliasTestObj->new;
is( $alias_test->perl_alias, 'C', "Host method aliases work" );

eval { $alias_test->aliased; };
like( $@, qr/aliased/, "Original method can't be called" );

my $overridden_alias_test = OverriddenAliasTestObj->new;
is( $overridden_alias_test->call_aliased_from_c, 'Perl',
    'Overriding aliased methods works' );

