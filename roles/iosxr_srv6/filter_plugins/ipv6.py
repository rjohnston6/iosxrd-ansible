"""IPv6 formatting filters for IOS-XR SRv6 locator models."""

from ipaddress import IPv6Network

from ansible.errors import AnsibleFilterError


def iosxr_ipv6_prefix(value):
    """Return a canonical IPv6 network prefix and reject host addresses."""
    try:
        return str(IPv6Network(value, strict=True))
    except (TypeError, ValueError) as error:
        raise AnsibleFilterError(
            "SRv6 locator prefix must be a valid "
            "IPv6 network in CIDR notation."
        ) from error


class FilterModule:
    def filters(self):
        return {"iosxr_ipv6_prefix": iosxr_ipv6_prefix}
