"""Minimal NetworkManager D-Bus fixture, on an explicitly private test bus."""
import json
import sys
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.bus.BusConnection(sys.argv[1])
name = dbus.service.BusName('org.freedesktop.NetworkManager', bus)
state_path = sys.argv[2]
base = '/org/freedesktop/NetworkManager'
class Object(dbus.service.Object):
    @dbus.service.method('org.freedesktop.NetworkManager', out_signature='ao')
    def GetDevices(self):
        return [base+'/Devices/1', base+'/Devices/2']

    @dbus.service.method('org.freedesktop.DBus.Properties', in_signature='s', out_signature='a{sv}')
    def GetAll(self, interface):
        i = self.__dbus_object_path__[-1]
        state = json.load(open(state_path))[i]
        if interface.endswith('.Device'):
            return dict(DeviceType=dbus.UInt32(8),State=dbus.UInt32(state),IpInterface='wan'+i,
                        Ip6Config=dbus.ObjectPath(base+'/IP6Config/'+i))
        return dict(Gateway=f'fd51:{i}::2',NameserverData=dbus.Array([
            dbus.Dictionary(dict(address=f'fd51:{i}::2'),signature='sv')], signature='a{sv}'))

    @dbus.service.signal('org.freedesktop.DBus.Properties', signature='sa{sv}as')
    def PropertiesChanged(self, interface, changed, invalidated): pass

objects = [Object(bus, base)]
for i in ['1','2']:
    objects.extend([Object(bus,base+'/Devices/'+i),Object(bus,base+'/IP6Config/'+i)])
def tick():
    objects[0].PropertiesChanged('org.freedesktop.NetworkManager',{},[])
    return True
GLib.timeout_add(200,tick)
GLib.MainLoop().run()
