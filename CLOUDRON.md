# cloudron-bluesky-pds

Bluesky maintains a [reference implementation](https://github.com/bluesky-social/atproto/tree/main/packages/pds) of an [AT Protocol PDS (Personal Data Server)](https://atproto.com/guides/the-at-stack#pds).  They also have [published a Docker image](https://github.com/bluesky-social/pds/pkgs/container/pds) for this PDS in the GitHub Container Registry.  Unfortunately this image won't work as-is in Cloudron.

Instead this project forks [bluesky-social/pds](https://github.com/bluesky-social/pds), the image source code project.  We pull in relevant upstream changes when possible.  Main differences:
1. Cloudron handles installation.  We don't need installer.sh which mostly sets up the host with Docker.
1. We can't use compose.yaml.  Cloudron only has support for dockerfile.
1. We don't need Caddy webserver.  Cloudron has a built in reverse proxy to map an app to a subdomain and handle inbound traffic.
1. Watchtower service won't be necessary either.  Cloudron handles application updates.

App version is pinned to the upstream project.

## Contributing

Fork this repository then see [App Packaging](https://docs.cloudron.io/packaging/) guidance.  Additional help is available in the [App Packaging and Developement forum](https://forum.cloudron.io/category/96/app-packaging-development).

Code for [Cloudron is hosted in Gitlab](https://git.cloudron.io/platform).
- [Cloudron Base Image documentation](https://git.cloudron.io/platform/docker-base-image).
- [Cloudron CLI](https://git.cloudron.io/platform/cloudron-cli)
- [Cloudron Box](https://git.cloudron.io/platform/box) is the code for the server.

Use the [local docker build workflow](https://docs.cloudron.io/packaging/tutorial#local-docker-build) since this app is published as a Custom App.  

General workflow is...
1. Make your changes
1. `cloudron build` to build in your local docker.
1. `cloudron install` to install the local docker image you built.  Choose a test location to install the app on your Cloudron server.
1. Make additional changes.  Then `cloudron build` then `cloudron update` to update the test location app.

Don't worry about publishing an image or adding a CloudronVersions.json entry.  I will take care of publishing the app after your changes are merged.

Submit a pull request.  You're welcome to send an email if I haven't seen it.

## Administration

Be aware that restarting the application or rebooting the Cloudron server will require all users to log in again to all authorized apps with access to their PDS.

Strongly recommend setting up a [secondary backup site](https://docs.cloudron.io/backups) at another storage provider other than your host.