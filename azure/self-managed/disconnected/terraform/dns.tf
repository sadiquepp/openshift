# The OpenShift installer creates its own private DNS zone for the cluster
# (<cluster-name>.<base-domain>) in the installer-managed resource group and
# links it to the VNet.  Pre-creating the same zone here would cause an
# "overlapping namespaces" error, so we intentionally leave DNS management
# to the installer.
#
# The base domain zone (e.g. azure.sadiqueonline.com) must already exist --
# see the README prerequisites.
