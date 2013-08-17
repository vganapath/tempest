# vim: tabstop=4 shiftwidth=4 softtabstop=4

# Copyright 2012 OpenStack, LLC
# All Rights Reserved.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

import os
import shlex
import subprocess
import sys

from sqlalchemy import create_engine, MetaData

from tempest.common.ssh import Client
from tempest.common.utils.data_utils import rand_name
from tempest import exceptions
from tempest.openstack.common import log as logging
from tempest.scenario import manager

LOG = logging.getLogger(__name__)


class WhiteboxTest(object):

    """
    Base test case class mixin for "whitebox tests"

    Whitebox tests are tests that have the following characteristics:

     * Test common and advanced operations against a set of servers
     * Use a client that it is possible to send random or bad data with
     * SSH into either a host or a guest in order to validate server state
     * May execute SQL queries directly against internal databases to verify
       the state of data records
    """
    pass


class ComputeWhiteboxTest(manager.OfficialClientTest):

    """
    Base smoke test case class for OpenStack Compute API (Nova)
    """

    @classmethod
    def setUpClass(cls):
        super(ComputeWhiteboxTest, cls).setUpClass()
        if not cls.config.whitebox.whitebox_enabled:
            msg = "Whitebox testing disabled"
            raise cls.skipException(msg)

        # Add some convenience attributes that tests use...
        cls.nova_dir = cls.config.whitebox.source_dir
        cls.compute_bin_dir = cls.config.whitebox.bin_dir
        cls.compute_config_path = cls.config.whitebox.config_path
        cls.build_interval = cls.config.compute.build_interval
        cls.build_timeout = cls.config.compute.build_timeout
        cls.ssh_user = cls.config.compute.ssh_user
        cls.image_ref = cls.config.compute.image_ref
        cls.image_ref_alt = cls.config.compute.image_ref_alt
        cls.flavor_ref = cls.config.compute.flavor_ref
        cls.flavor_ref_alt = cls.config.compute.flavor_ref_alt

    # NOTE(afazekas): Mimics the helper method used in the api tests
    @classmethod
    def create_server(cls, **kwargs):
        flavor_ref = cls.config.compute.flavor_ref
        image_ref = cls.config.compute.image_ref
        name = rand_name(cls.__name__ + "-instance")
        if 'name' in kwargs:
            name = kwargs.pop('name')
        flavor = kwargs.get('flavor', flavor_ref)
        image_id = kwargs.get('image_id', image_ref)

        server = cls.compute_client.servers.create(
            name, image_id, flavor, **kwargs)

        if 'wait_until' in kwargs:
            cls.status_timeout(cls.compute_client.servers, server.id,
                               server['id'], kwargs['wait_until'])

        server = cls.compute_client.servers.get(server.id)
        cls.set_resource(name, server)
        return server

    @classmethod
    def get_db_handle_and_meta(cls, database='nova'):
        """Return a connection handle and metadata of an OpenStack database."""
        engine_args = {"echo": False,
                       "convert_unicode": True,
                       "pool_recycle": 3600
                       }

        try:
            engine = create_engine(cls.config.whitebox.db_uri, **engine_args)
            connection = engine.connect()
            meta = MetaData()
            meta.reflect(bind=engine)

        except Exception as e:
            raise exceptions.SQLException(message=e)

        return connection, meta

    def nova_manage(self, category, action, params):
        """Executes nova-manage command for the given action."""

        nova_manage_path = os.path.join(self.compute_bin_dir, 'nova-manage')
        cmd = ' '.join([nova_manage_path, category, action, params])

        if self.deploy_mode == 'devstack-local':
            if not os.path.isdir(self.nova_dir):
                sys.exit("Cannot find Nova source directory: %s" %
                         self.nova_dir)

            cmd = shlex.split(cmd)
            result = subprocess.Popen(cmd, stdout=subprocess.PIPE)

        # TODO(rohitk): Need to define host connection parameters in config
        else:
            client = self.get_ssh_connection(self.config.whitebox.api_host,
                                             self.config.whitebox.api_user,
                                             self.config.whitebox.api_passwd)
            result = client.exec_command(cmd)

        return result

    def get_ssh_connection(self, host, username, password):
        """Create an SSH connection object to a host."""
        ssh_timeout = self.config.compute.ssh_timeout
        ssh_client = Client(host, username, password, ssh_timeout)
        if not ssh_client.test_connection_auth():
            raise exceptions.SSHTimeout()
        else:
            return ssh_client
