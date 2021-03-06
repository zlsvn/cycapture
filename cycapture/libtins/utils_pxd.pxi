# -*- coding: utf-8 -*-

cdef extern from "tins/utils.h" namespace "Tins::Utils" nogil:

    ctypedef struct cppRouteEntry "Tins::Utils::RouteEntry":
        string interface
        cppIPv4Address destination
        cppIPv4Address gateway
        cppIPv4Address mask

    cppIPv4Address cpp_resolve_domain "Tins::Utils::resolve_domain" (const string &to_resolve)
    cppIPv6Address cpp_resolve_domain6 "Tins::Utils::resolve_domain6" (const string &to_resolve)
    cppHWAddress6 cpp_resolve_hwaddr "Tins::Utils::resolve_hwaddr" (const cppNetworkInterface &iface, cppIPv4Address ip, cppPacketSender &sender)
    cppHWAddress6 cpp_resolve_hwaddr "Tins::Utils::resolve_hwaddr" (cppIPv4Address ip, cppPacketSender &sender)

    cpp_set[string] cpp_network_interfaces "Tins::Utils::network_interfaces"()

    cpp_bool gateway_from_ip(cppIPv4Address ip, cppIPv4Address &gw_addr)

    vector[cppRouteEntry] route_entries()

    uint32_t crc32(const uint8_t* data, uint32_t data_size)
    uint16_t cpp_channel_to_mhz "Tins::Utils::channel_to_mhz" (uint16_t channel)
    uint16_t cpp_mhz_to_channel "Tins::Utils::mhz_to_channel" (uint16_t mhz)
    string   cpp_pdutype_to_string "Tins::Utils::to_string" (PDUType pduType)
    uint32_t do_checksum(const uint8_t *start, const uint8_t *end)
    uint32_t pseudoheader_checksum(cppIPv4Address source_ip, cppIPv4Address dest_ip, uint32_t length, uint32_t flag)
    uint32_t pseudoheader_checksum(cppIPv6Address source_ip, cppIPv6Address dest_ip, uint32_t length, uint32_t flag)


cdef class RouteEntry(object):
    cdef readonly bytes interface
    cdef readonly IPv4Address destination
    cdef readonly IPv4Address gateway
    cdef readonly IPv4Address mask

    cdef equals(self, other)

    @staticmethod
    cdef from_cpp(cppRouteEntry r)

cdef class Utils(object):
    pass
