"""Public VM inventory and credentials for deployment and protocol exercises."""
import copy
import json
from pathlib import Path
import shutil
import sys

import yaml

from scripts.network.provider_groups import grouped_outbounds


def generate(source, keys, output):
    sys.path.insert(0, str(source / 'scripts/vps'))
    from model import Inventory
    from prepare import generate as prepare_vps

    document = yaml.safe_load((source / 'data/secrets/vps.example.yaml').read_text())
    for name, node in document['nodes'].items():
        node.update(
            serverName=f'{name}.test.nix',
            interface='eth0',
            dhcp=(name == 'west'),
            gateway='192.0.2.30',
            nameservers=['192.0.2.30#dns.test.nix', '192.0.2.31#dns.test.nix'],
            sshHost=f'deploy-{name}',
            modules=['modules/vps/docker.nix'] if name == 'edge' else ['modules/vps/http-origin.nix'],
        )
        if name == 'edge':
            node['addresses'] = [node['address'] + '/24']
        node['sshServer'] = {
            'port': 2222 if name == 'edge' else 22022,
            'rootAuthorizedKeys': [(keys / 'ssh.pub').read_text().strip()],
        }
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
        data['secrets']['west-http-origin-prefix'] = f'/fixture-origin-{generation}'
        if generation == 'v2':
            data['subscriptions']['primary']['key'] = 'a5' * 32
        vps = Inventory(data)
        prepared = output / generation
        prepare_vps(vps, prepared)
        meta = json.loads((prepared / 'metadata.json').read_text())
        for node, info in meta['nodes'].items():
            target = output / 'nodes' / node / generation
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(prepared / 'nodes' / node / info['release'], target)
    provider = json.loads((output / 'v1/subscriptions/primary/trojan/linux.json').read_text())
    paths = [path for path in provider['outbounds']
             if path['tag'] in provider['exits']['us']['paths']]
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
