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

package Clownfish::ParamList;
use Clownfish;

1;

__END__

__POD__

=head1 NAME

Clownfish::ParamList - parameter list.

=head1 DESCRIPTION

=head1 METHODS

=head2 new

    my $param_list = Clownfish::ParamList->new(
        variadic => 1,    # default: false
    );

=over

=item * B<variadic> - Should be true if the function is variadic.

=back

=head2 add_param

    $param_list->add_param( $variable, $value );

Add a parameter to the ParamList.

=over

=item * B<variable> - A L<Clownfish::Variable>. 

=item * B<value> - The default value for the parameter, which should be undef
if there is no such value and the parameter is required.

=back

=head2 get_variables get_initial_values variadic

Accessors. 

=head2 num_vars

Return the number of variables in the ParamList, including "self" for methods.

=head2 to_c

    # Prints "Obj* self, Foo* foo, Bar* bar".
    print $param_list->to_c;

Return a list of the variable's types and names, joined by commas.

=head2 name_list

    # Prints "self, foo, bar".
    print $param_list->name_list;

Return the variable's names, joined by commas.

=cut
