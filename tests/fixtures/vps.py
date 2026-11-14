"""Public VM inventory and credentials for deployment and protocol exercises."""
import copy
import json
from pathlib import Path
import sys

import yaml

from scripts.vps.model import Inventory

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts/network'))
from render import grouped_outbounds


def generate(source, keys, output):
    document = yaml.safe_load((source / 'data/secrets/vps.example.yaml').read_text())
    for name, node in document['nodes'].items():
        node.update(serverName=f'{name}.test.nix', interface='eth0', dhcp=(name == 'west'),
                    addresses=[node['address'] + '/24'], sshHost=f'deploy-{name}')
        node['sshServer']['rootAuthorizedKeys'] = [(keys / 'ssh.pub').read_text().strip()]
    document['workers']['certificates']['url'] = 'https://cert.test.nix:8443'
    document['nodes']['west']['web'] = {'app.test.nix': 'http://127.0.0.1:18090'}
    document['exits'] |= {
        'us': {'nodes': ['edge', 'west'], 'type': 'socks', 'options': {'server': '192.0.2.30', 'server_port': 1080}},
        'west-wg': {'nodes': ['west'], 'type': 'wireguard', 'options': {
            'address': ['10.88.0.2/32'], 'private_key': (keys / 'wg-client').read_text().strip(),
            'peers': [{'address': '192.0.2.30', 'port': 51820, 'public_key': (keys / 'wg-server.pub').read_text().strip(),
                       'allowed_ips': ['0.0.0.0/0']}]}},
        'west-openvpn': {'nodes': ['west'], 'type': 'openvpn-client', 'options': {
            'server': '192.0.2.30', 'server_port': 1194, 'network': 'tcp', 'username': 'fixture', 'password': 'fixture',
            'tls': {'server_name': '*.test.nix', 'server_name_type': 'name',
                    'certificate': (keys / 'ca.crt').read_text()}}},
    }
    document['subscriptions']['primary']['exits'] = list(document['exits'])
    document['subscriptions']['primary']['groups'] = {'proxy': {'exits': list(document['exits']), 'default': 'west-native'}}
    for exit_ in document['exits'].values():
        exit_['dns'] = [{
            'type': 'https', 'server': '198.51.100.30', 'server_port': 24443 + branch,
            'path': '/dns-query', 'tls': {'enabled': True, 'server_name': 'dns.test.nix',
                                        'certificate': (keys / 'ca.crt').read_text()},
        } for branch in range(2)]
    for generation in ('v1', 'v2'):
        data = copy.deepcopy(document)
        if generation == 'v2':
            data['subscriptions']['primary']['key'] = 'a5' * 32
        vps = Inventory(data)
        for node in vps.nodes:
            directory = output / 'nodes' / node / generation
            directory.mkdir(parents=True)
            (directory / 'proxy.json').write_text(json.dumps(vps.server(node)))
            (directory / 'certificate.json').write_text(json.dumps(vps.certificate_request(node)))
        (output / f'provider-{generation}.json').write_text(json.dumps(vps.provider('primary')))
    provider = Inventory(document).provider('primary')
    paths = [path for path in provider['outbounds']
             if path['tag'].endswith('-us-trojan')]
    for path in paths:
        path['tls']['certificate_path'] = str(keys / 'ca.crt')
    provider = {'outbounds': paths, 'exits': {'us': {'paths': [p['tag'] for p in paths]}},
                'groups': {'proxy': {'exits': ['us'], 'default': 'us'}}}
    groups = grouped_outbounds(provider)
    groups[0].update(url='http://198.51.100.30:18080/', interval='1s', tolerance=0)
    (output / 'failover.json').write_text(json.dumps({
        'inbounds': [{'type': 'socks', 'listen': '127.0.0.1', 'listen_port': 11080}],
        'outbounds': groups + paths, 'route': {'final': 'proxy'},
        'experimental': {'clash_api': {'external_controller': '127.0.0.1:19090'}},
    }))


if __name__ == '__main__':
    generate(*map(Path, sys.argv[1:]))
