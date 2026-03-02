#
# Copyright 2024 Centreon (http://www.centreon.com/)
#
# Centreon is a full-fledged industry-strength solution that meets
# the needs in IT infrastructure and application monitoring for
# service performance.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

package apps::proxmox::backupserver::restapi::mode::datastoreusage;

use base qw(centreon::plugins::templates::counter);

use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
use centreon::plugins::templates::catalog_functions qw(catalog_status_threshold_ng);

sub custom_status_output {
    my ($self, %options) = @_;

    return 'state: ' . $self->{result_values}->{state};
}

sub custom_datastore_perfdata {
    my ($self, %options) = @_;

    $self->{output}->perfdata_add(
        nlabel => 'datastore.space.usage.bytes',
        unit => 'B',
        instances => $self->{result_values}->{display},
        value => $self->{result_values}->{used},
        warning => $self->{perfdata}->get_perfdata_for_output(label => 'warning-' . $self->{thlabel}, total => $self->{result_values}->{total}, cast_int => 1),
        critical => $self->{perfdata}->get_perfdata_for_output(label => 'critical-' . $self->{thlabel}, total => $self->{result_values}->{total}, cast_int => 1),
        min => 0, max => $self->{result_values}->{total}
    );
}

sub custom_datastore_threshold {
    my ($self, %options) = @_;

    my $exit = $self->{perfdata}->threshold_check(
        value => $self->{result_values}->{prct_used},
        threshold => [ { label => 'critical-' . $self->{thlabel}, exit_litteral => 'critical' }, { label => 'warning-' . $self->{thlabel}, exit_litteral => 'warning' } ]
    );
    return $exit;
}

sub custom_datastore_output {
    my ($self, %options) = @_;

    my ($total_size_value, $total_size_unit) = $self->{perfdata}->change_bytes(value => $self->{result_values}->{total});
    my ($total_used_value, $total_used_unit) = $self->{perfdata}->change_bytes(value => $self->{result_values}->{used});
    my ($total_free_value, $total_free_unit) = $self->{perfdata}->change_bytes(value => $self->{result_values}->{free});

    return sprintf(
        "space total: %s used: %s (%.2f%%) free: %s (%.2f%%)",
        $total_size_value . " " . $total_size_unit,
        $total_used_value . " " . $total_used_unit, $self->{result_values}->{prct_used},
        $total_free_value . " " . $total_free_unit, $self->{result_values}->{prct_free}
    );
}

sub custom_datastore_calc {
    my ($self, %options) = @_;

    $self->{result_values}->{display} = $options{new_datas}->{$self->{instance} . '_display'};
    $self->{result_values}->{total} = $options{new_datas}->{$self->{instance} . '_datastore_total'};
    $self->{result_values}->{used} = $options{new_datas}->{$self->{instance} . '_datastore_used'};
    $self->{result_values}->{free} = $self->{result_values}->{total} - $self->{result_values}->{used};

    return -10 if ($self->{result_values}->{total} <= 0);

    $self->{result_values}->{prct_free} = $self->{result_values}->{free} * 100 / $self->{result_values}->{total};
    $self->{result_values}->{prct_used} = $self->{result_values}->{used} * 100 / $self->{result_values}->{total};

    return 0;
}

sub prefix_datastores_output {
    my ($self, %options) = @_;

    return "Datastore '" . $options{instance_value}->{display} . "' ";
}

sub set_counters {
    my ($self, %options) = @_;

    $self->{maps_counters_type} = [
        { name => 'datastores', type => 1, cb_prefix_output => 'prefix_datastores_output',
          message_multiple => 'All datastores are ok', skipped_code => { -10 => 1, -11 => 1 } }
    ];

    $self->{maps_counters}->{datastores} = [
        { label => 'datastore', set => {
                key_values => [ { name => 'datastore_used' }, { name => 'datastore_total' }, { name => 'display' } ],
                closure_custom_calc => $self->can('custom_datastore_calc'),
                closure_custom_output => $self->can('custom_datastore_output'),
                closure_custom_perfdata => $self->can('custom_datastore_perfdata'),
                closure_custom_threshold_check => $self->can('custom_datastore_threshold')
            }
        }
    ];
}

sub new {
    my ($class, %options) = @_;
    my $self = $class->SUPER::new(package => __PACKAGE__, %options, statefile => 1, force_new_perfdata => 1);
    bless $self, $class;

    # $options{options}->add_options(arguments => {
    #     'storage-id:s'   => { name => 'storage_id' },
    #     'storage-name:s' => { name => 'storage_name' },
    #     'filter-name:s'  => { name => 'filter_name' },
    #     'use-name'       => { name => 'use_name' },
    #     'node-id:s'      => { name => 'node_id' },
    #     'node-name:s'    => { name => 'node_name' }
    # });


    $options{options}->add_options(arguments => {
        'datastore-name:s'  => { name => 'datastore_name' },
        'filter-name:s'     => { name => 'filter_name' }
    });

    $self->{statefile_cache_datastores} = centreon::plugins::statefile->new(%options);
    return $self;
}

sub check_options {
    my ($self, %options) = @_;
    $self->SUPER::check_options(%options);

    $self->{statefile_cache_datastores}->check_options(%options);
}

sub manage_selection {
    my ($self, %options) = @_;

    my $results = $options{custom}->api_get_datastores(
        datastore_name => $self->{option_results}->{datastore_name},
        statefile => $self->{statefile_cache_datastores}
    );

    $self->{datastores} = {};
    foreach my $datastore (keys %{$results}) {
        next if (!defined($results->{$datastore}->{Stats}));

        if (defined($self->{option_results}->{filter_name}) && $self->{option_results}->{filter_name} ne '' &&
            $datastore !~ /$self->{option_results}->{filter_name}/) {
            $self->{output}->output_add(long_msg => "skipping  '" . $datastore . "': not matching filter.", debug => 1);
            next;
        }

        $self->{datastores}->{$datastore} = {
            display => $datastore,
            datastore_used => $results->{$datastore}->{Stats}->{used},
            datastore_total => $results->{$datastore}->{Stats}->{total}
        };
    }

    if (scalar(keys %{$self->{datastores}}) <= 0) {
        $self->{output}->add_option_msg(short_msg => "No datastore found.");
        $self->{output}->option_exit();
    }

    my $hostnames = $options{custom}->get_hostnames();
    $self->{cache_name} = 'proxmox_' . $self->{mode} . '_' . $hostnames . '_' . $options{custom}->get_port() . '_' .
        md5_hex(
            (defined($self->{option_results}->{filter_name}) ? $self->{option_results}->{filter_name} : '') . '_' .
            (defined($self->{option_results}->{datastore_name}) ? $self->{option_results}->{datastore_name} : '')
        );
        
}

1;

__END__

=head1 MODE

Check datastore usage.

=over 8

=item B<--datastore-name>

Exact datastore name (if multiple names: names separated by ':').

=item B<--filter-name>

Filter by datastore name (can be a regexp).

=item B<--warning-*> B<--critical-*>

Thresholds.
Can be: 'datastore' (%).

=back

=cut
