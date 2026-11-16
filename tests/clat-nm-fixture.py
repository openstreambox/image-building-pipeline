"""Minimal NetworkManager D-Bus fixture, on an explicitly private test bus."""
import json
import os
import sys
import socket
import time
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.bus.BusConnection(sys.argv[1])
name = dbus.service.BusName('org.freedesktop.NetworkManager', bus)
state_path = sys.argv[2]
base = '/org/freedesktop/NetworkManager'
PROPS = 'org.freedesktop.DBus.Properties'


def snapshot():
    return json.load(open(state_path))


class Object(dbus.service.Object):
    @dbus.service.method('org.freedesktop.NetworkManager', out_signature='ao')
    def GetDevices(self):
        # A present '.slow' file holds the caller in a slow reconciliation;
        # '.entered' tells the test that it has started.
        if os.path.exists(state_path + '.slow'):
            open(state_path + '.entered', 'w').close()
            time.sleep(3)
        return [base+'/Devices/1', base+'/Devices/2']

    @dbus.service.method(PROPS, in_signature='ss', out_signature='v')
    def Get(self, interface, prop):
        # Only the manager's ActiveConnections; an IPv6 shared connection
        # exists while the state has "shared6": true.
        if prop != 'ActiveConnections':
            raise dbus.exceptions.DBusException('unsupported property')
        return dbus.Array([dbus.ObjectPath(base+'/ActiveConnection/shared')] if snapshot().get('shared6') else [],
                          signature='o')

    @dbus.service.method(PROPS, in_signature='s', out_signature='a{sv}')
    def GetAll(self, interface):
        i = self.__dbus_object_path__[-1]
        state = snapshot()
        if interface.endswith('.Device'):
            return dict(DeviceType=dbus.UInt32(8),State=dbus.UInt32(state[i]),IpInterface='cell.'+i,
                        ActiveConnection=dbus.ObjectPath(base+'/ActiveConnection/'+i),
                        Ip6Config=dbus.ObjectPath('/' if state.get('ipv4_only') and i=='1' else base+'/IP6Config/'+i))
        return dict(Gateway=f'fd51:{i}::2', Nameservers=dbus.Array([
            dbus.ByteArray(socket.inet_pton(socket.AF_INET6, f'fd51:{i}::2'))], signature='ay'))

    @dbus.service.signal(PROPS, signature='sa{sv}as')
    def PropertiesChanged(self, interface, changed, invalidated): pass


class SharedActive(dbus.service.Object):
    @dbus.service.method(PROPS, in_signature='ss', out_signature='v')
    def Get(self, interface, prop):
        return {'State': dbus.UInt32(2), 'Connection': dbus.ObjectPath(base+'/Settings/shared')}[prop]


class SharedSettings(dbus.service.Object):
    @dbus.service.method('org.freedesktop.NetworkManager.Settings.Connection', out_signature='a{sa{sv}}')
    def GetSettings(self):
        return {'connection': {'id': 'hotspot', 'type': '802-3-ethernet'},
                'ipv6': {'method': 'shared'}}


objects = [Object(bus, base), SharedActive(bus, base+'/ActiveConnection/shared'),
           SharedSettings(bus, base+'/Settings/shared')]
for i in ['1','2']:
    objects.extend([Object(bus,base+'/Devices/'+i),Object(bus,base+'/IP6Config/'+i)])
previous = [None]
def tick():
    current = open(state_path).read()
    if current == previous[0]:
        return True
    previous[0] = current
    objects[0].PropertiesChanged('org.freedesktop.NetworkManager',{},[])
    return True
GLib.timeout_add(200,tick)
GLib.MainLoop().run()
