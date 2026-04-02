# Upgrading from a previous version

Minor updates should be installable in-place via the Foundry admin screen. **Major Foundry updates need some planning**.

First, log in to the Foundry admin interface. From the Foundry version update screen, there's an option to test your add-ons for compatibility after checking versions, so you can find out what will work and what won't. Many add-ons usually need to be updated, so it's good to know what might work and what won't.

Then, make sure to back up all the Foundry data from your existing EC2 instance.

Once you've downloaded all your foundry worlds and user data, make a note of all the add-ons you use as you'll likely need to reinstall them manually. Many add-ons change repositories, dependencies, or simply aren't compatible and may no longer be maintained.

Then, deploy a new CloudFormation stack with the new version of Foundry.

## Recommended migration method (simple and secure)

Use `utils/migrate_foundry_data.sh` from your local machine. This script streams data directly from old server to new server over SSH and preserves ownership/perms/timestamps/ACLs/xattrs.

Important:
- You do not need to upload your private key to either EC2 instance.
- Run this from your laptop/workstation where your `.pem` key already exists.
- Use the same keypair for both old and new instances.

### 1. Stop Foundry on the old server

This avoids files changing during transfer.

```bash
ssh -i /path/to/key.pem ec2-user@OLD_SERVER_IP "sudo systemctl stop foundry"
```

### 2. (Optional) dry run

Dry run validates SSH access and paths but does not copy data.

```bash
chmod +x ./utils/migrate_foundry_data.sh

./utils/migrate_foundry_data.sh \
  --key /path/to/key.pem \
  --source-host OLD_SERVER_IP \
  --dest-host NEW_SERVER_IP \
  --source-user ec2-user \
  --dest-user ec2-user \
  --source-path /foundrydata/Data \
  --dest-path /foundrydata/Data \
  --dry-run
```

### 3. Run the actual copy

```bash
./utils/migrate_foundry_data.sh \
  --key /path/to/key.pem \
  --source-host OLD_SERVER_IP \
  --dest-host NEW_SERVER_IP \
  --source-user ec2-user \
  --dest-user ec2-user \
  --source-path /foundrydata/Data \
  --dest-path /foundrydata/Data
```

What this does:
- Verifies SSH connectivity to both servers.
- Verifies source folder exists and destination folder exists (or creates it).
- Streams a `tar` archive from old server to new server via your local machine.
- Preserves ownership and permissions using `sudo` on both ends.
- Runs `fix_folder_permissions.sh` on the destination if present.
- Restarts Foundry on the destination.

### 4. Validate on the new server

- Open your Foundry URL.
- Enter your license key and admin password if prompted.
- Reinstall/update add-ons as needed.
- Start each world and let migrations run.

### 5. Fallback plan

If something goes wrong, stop the new EC2 and start the old EC2 again.

At any point if something goes awry, you can always stop the new EC2 and start the old EC2 to test.

Once up and running, Foundry should prompt you to upgrade the save format if it's changed in any way. Note that this is an irreversible process, so keep a back-up of the old version at least for a little while!

When you're happy that the new server and Foundry version is working as you wish, stop the old EC2 so it cannot race DNS updates, then tear down the _old_ CloudFormation stack.

Make sure to update the resource scheduler (to start/stop the new EC2 on your selected schedule) if you're using it.

_Note: You can do a major version upgrade in-place on your current server, but that's at your own initiative as it can be risky._
