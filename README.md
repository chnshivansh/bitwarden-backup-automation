# Bitwarden Vault Automated Backup Pipeline

A straightforward, secure bash script and systemd setup for Linux servers to automatically export, encrypt, and back up a Bitwarden password vault to Cloudflare R2 storage.

## The Goal
Bitwarden provides excellent security, but it lacks a built-in way to automatically back up your encrypted vault to your own external storage. Relying on manual exports is risky because humans forget. 

The goal of this project is to fully automate the backup process on a headless Linux server, while making sure the master password and API keys are **never stored in a plain text file on the hard drive.**

---

## How It Works: Step-by-Step

### 1. Secure Credential Handling (AWS IAM & Secrets Manager)
To automate the Bitwarden CLI, the script needs your master password and API keys. Storing these in a local `.env` file or hardcoding them into the script is a massive security risk. If an automated bot or attacker ever gains access to your server, they can easily read that file and steal your passwords.

Instead, this setup relies on AWS Secrets Manager. 
* By attaching an **IAM Role** directly to the AWS EC2 instance, you give the server's hardware permission to fetch the passwords from AWS dynamically. 
* When the script runs, it pulls the master password and Cloudflare API keys directly into the server's temporary memory (RAM) as environment variables. 
* It unlocks the vault, processes the backup, and immediately clears the memory. 
If the server is offline or sitting idle, there are absolutely zero passwords on the hard drive to steal.

### 2. Exporting to the Linux RAM Disk
When the script downloads the vault from Bitwarden, it saves the file to `/dev/shm/vault.json`. 

The `/dev/shm` directory is the native Linux RAM disk. This means the unencrypted vault data is kept entirely in the system's volatile memory and never touches the physical hard drive.

### 3. The Backup Engine (Restic & Cloudflare R2)
Once the vault is in memory, the script hands it over to **Restic**. 
Restic encrypts the file again, breaks it into small chunks, and uploads it to a Cloudflare R2 bucket. Restic handles deduplication automatically, meaning it only uploads data that has actually changed since the last backup. This keeps storage usage incredibly low.

* **The S3 Environment Variables:** Cloudflare R2 is an S3-compatible storage provider. Because Restic expects to talk to Amazon S3, the script passes the Cloudflare API keys into the temporary RAM using Amazon's standard environment variables (`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`). This allows Restic to authenticate with Cloudflare without leaving a permanent record of the keys in the Linux `.bash_history` file.
* **Source:** [Restic Amazon S3 Setup](https://restic.readthedocs.io/en/latest/030_preparing_a_new_repo.html#amazon-s3)

### 4. Process Scheduling (Systemd)
Instead of using standard `cron` jobs, which are blind and do not handle failures or server reboots well, this project uses Linux Systemd to manage the schedule. The setup is split into two isolated files:

**The Service File (`bw-backup.service`)**
This file contains the instructions to run the script. 
* It uses `Type=oneshot`, meaning systemd will wait for the script to completely finish and exit before marking the job as successful. 
* We specifically **do not** include an `[Install]` block. This guarantees the backup cannot accidentally run every time you reboot the server. It only runs when explicitly triggered.
* **Source:** [Systemd Service Documentation](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#)

**The Timer File (`bw-backup.timer`)**
This handles the actual schedule (e.g., run every day at 2:00 AM). 
* By separating the timer from the service, we can use the `Persistent=true` setting. 
* If your server happens to be turned off during the scheduled backup time, systemd will remember that it missed the backup. It will then trigger the service immediately when the server boots back up.

### 5. Phone Notifications
To ensure the backup actually worked without having to SSH into the server to check the logs manually, the script finishes by sending a simple web request to `ntfy.sh`. You get a push notification on your phone telling you if the backup succeeded or failed and how long the process took.

---

## Prerequisites for Deployment
To run this pipeline on your own machine, you will need:
1. A Linux server (AWS EC2 used in this specific setup).
2. An AWS IAM Role attached to the server with read access to your AWS Secrets Manager JSON.
3. A Cloudflare R2 bucket and S3 API credentials.
4. The standalone Bitwarden CLI binary (`bw`) installed and accessible in your system path.
5. `restic` and `jq` installed on the host machine.
