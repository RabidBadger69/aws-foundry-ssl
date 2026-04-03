# AWS Foundry VTT CloudFormation Deployment with TLS Encryption

This repository is forked from [**mikehdt/aws-foundry-ssl**](https://github.com/mikehdt/aws-foundry-ssl), which itself builds on the earlier work by Lupert and Cat, and has since diverged significantly.

It has been tested against Foundry VTT 14 and is confirmed working as of April 3, 2026.

## High-Level Changes

- Supports modern Foundry VTT releases, including Foundry 14
- Amazon Linux 2023 on Graviton EC2s
- Node 24.x
- [IPv6 support](docs/IPv6.md)
- Improved setup logging and CloudWatch visibility
- Dynamic DNS reliability fixes for Route53 updates at boot
- Foundry health check and automatic restart support
- Configurable root volume sizing
- Utility scripts for upgrades, permissions, and data migration

Note this is just something being done in my spare time and for fun/interest. If you have any contributions, they're welcome. Please note that I'm only focusing on AWS as the supported hosting service.

## Installation

You'll need some technical expertise and basic familiarity with AWS to get this running. It's not _quite_ click-ops, but it's close. Some parts do require some one-off click-ops, such as generating the EC2 security pair.

You can also refer to the original repo's wiki, but the gist is:

### Foundry VTT Download

Download the `NodeJS` installer for Foundry VTT from the [Foundry VTT website](https://foundryvtt.com/). Then either:

- Upload it to Google Drive, make the link publicly shared (anyone with the link can view), or
- Upload it somewhere else it can be fetched publicly, or
- Have a Foundry VTT Patreon download link handy, or
- Generate a time-limited link from the Foundry VTT site; This option isn't really recommended, but if that works for you then that's cool

Once your server is up and running, if you used eg. a Google Drive link or your own hosted site, you can remove the installer as it's not used past the initial deployment.

### AWS Pre-setup

This only needs to be done _once_, no matter how many times you redeploy.

- Create an SSH key in **EC2**, under `EC2 / Key Pairs`
  - Keep the downloaded private keypair (PEM or PPK) file safe, you'll need it for [SSH / SCP access](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/connect-to-linux-instance.html) to the EC2 server instance
  - If you tear down and redeploy the CloudFormation stack you can reuse the same SSH key
  - Consider rotating these keys regularly as a good security practice

### AWS Setup

**Note:** This script currently only supports your _default VPC_, which should have been created automatically when you first signed up for your AWS account.

If you want to use IPv6, see [the IPv6 docs](docs/IPv6.md) for how to configure your default VPC.

- Go to **CloudFormation** and choose to **Create a Stack** with new resources
  - Leave `Template is Ready` selected
  - Choose `Upload a template file`
  - Upload the `/cloudformation/Foundry_Deployment.yaml` file from this project
  - Fill in and check _all_ the details. I've tried to provide sensible defaults. At a minimum if you leave the defaults, the ones that need to be filled in are:
    - The link for downloading Foundry
    - Your domain name and TLD eg. `mydomain.com`
      - **Important:** Do _not_ include `www` or any other sub-domain prefix
    - Your email address for LetsEncrypt TLS (https) certificate issuance
    - The SSH keypair you previously set up in `EC2 / Key Pairs`
    - Choose whether the S3 bucket already exists, or if it should be created
    - The S3 bucket name for storing files
      - This name must be _globally unique_ across all S3 buckets that exist on AWS
      - If you host Foundry on eg. `foundry.mydomain.com` then `foundry-mydomain-com` is a good recommendation

It should be automated from there. If all goes well, the server will take around five minutes or so to become accessible.

## Instructions for Use

At a high level, the workflow is:

1. Download the Foundry VTT NodeJS build and make it reachable from AWS using a public or time-limited URL.
2. Complete the one-time AWS pre-setup, especially your EC2 key pair.
3. Deploy [cloudformation/Foundry_Deployment.yaml](/Users/danielatherton/Documents/Development/aws-foundry-ssl/cloudformation/Foundry_Deployment.yaml) through CloudFormation.
4. Wait for the stack to finish, then open your configured Foundry domain.
5. If needed, use SSH and CloudWatch logs to verify setup or troubleshoot first boot.

For ongoing operation:

- Start and stop the EC2 instance manually, or use the Systems Manager schedule described below.
- Keep the instance packages updated periodically.
- Use the upgrade docs before major Foundry or stack changes.

### Optional SSH Access

If you want to allow yourself access via SSH, you must specify a valid [subnet range](https://www.calculator.net/ip-subnet-calculator.html) for your [IPv4 / IPv6 address](https://www.whatismyip.com/).

- For IPv4 access, use `[your IPv4 address]/32` unless you know what you're doing
- For IPv6 access, use `[your IPv6 address]/128` unless you know what you're doing
  - As IPv6 device addresses change quite frequently, it's likely this will need to be updated often until you know what a more permissive subnet range looks like for you; A more permissive IPv6 range might be `0123:4567:89ab::/64` for example

You can always manually add or update SSH access later in `EC2 / Security Groups` in the AWS Console.

## Running the Server on a Schedule

If you don't have a need for your Foundry server to run 24/7, **AWS Systems Manager** lets you configure a simple schedule to start and stop your EC2 Foundry instance and save on hosting costs. Note: AWS change the interface for this semi-regularly, but hopefully the concepts should still hold.

1. From the AWS Console, navigate to `Systems Manager` and then look under the Change Management Tools heading
2. Then,

   - if this is your first time using System Manager, choose `Quick Setup`, or
   - if you already have other services configured in Systems Manager, choose `Quick Setup` and then click the `Create` button

3. Choose `Resource Scheduler`

   - Enter a tag name of `Name` with a value of `[the Foundry CloudFormation stack name]-Server`
     - You can find the server name in `EC2 / Instances` if you're unsure
   - Choose which days and what times on those days you want the server to be active
   - Choose `Current Account` and `Current Region` as targets unless your needs differ

4. Create the schedule

Once it's successfully provisioned, the next time it ticks over a trigger time the Foundry EC2 server will be started or stopped as appropriate, saving you from paying for time that you aren't using the server.

If you _do_ need to access the server outside of the schedule, you can always start and stop it manually from the EC2 list without affecting the Resource Scheduler.

If your needs are more complex, you could instead consider setting up the [AWS Instance Scheduler stack](https://aws.amazon.com/solutions/implementations/instance-scheduler-on-aws/). There's a nominal cost per month to run the services required.

## Security and Updates

Linux auto-patching is enabled by default. A utility script `utils/kernel_updates.sh` also exists to help you manage this if you want to disable, re-enable, or run it manually.

It's also recommended to SSH into the instance and run `sudo dnf upgrade` every so often to make sure your packages are up to date with the latest fixes and security releases.

## Upgrading From a Previous Installation

See [Upgrading](docs/UPGRADING.md).

If you are moving an existing Foundry world or data directory to a fresh server, use [`utils/migrate_foundry_data.sh`](utils/migrate_foundry_data.sh). The script securely copies `/foundrydata/Data` from one host to another over SSH, preserves ownership and permissions, and restarts Foundry on the destination when the transfer completes.

Example dry run:

```bash
./utils/migrate_foundry_data.sh \
  --key /path/to/key.pem \
  --source-host old-server.example.com \
  --dest-host new-server.example.com \
  --dry-run
```

Then rerun the same command without `--dry-run` to perform the transfer.

## Debugging Failed CloudFormation

As long as you can get as far as the EC2 being spun up, then:

- If you encounter a creation error, try setting CloudFormation to _preserve_ resources instead of _rollback_ so you can check the troublesome resources
- Disable LetsEncrypt certificate requests (`UseLetsEncryptTLS` set to `False`), until you're happy that the stack build will work, to avoid running into the certificate issuance limit
- Add your IP to the Inbound rules of the created Security Group (if you didn't already during the CloudFormation config)
- Grab the EC2's IP from the EC2 web console details
- Open up PuTTy or similar, connect to the IP using the SSH keypair (I'd recommend to only accept the key _once_, rather than accept _always_, as you may end up destroying this instance)
- Check the setup logs
  - These can be found in CloudWatch under `foundry-setup`. Or if you SSH into the EC2,
  - `sudo tail -f /tmp/foundry-setup.log` if setup scripts are still running, or
  - `sudo cat /tmp/foundry-setup.log | less` if setup scripts have finished running

Hopefully that gives you some insight in what's going on...

### LetsEncrypt TLS Issuance Limits

Should you run into the allowed LetsEncrypt TLS requests of _5 requests per Fully Qualified Domain Name, per week_, you'll need to wait _one week_ before trying again. You can still access your instance over _non-secure_ `http`.

After a week, you can re-run the issuance request manually, or if you haven't done anything major, you may just tear down the CloudFormation stack and start over.
