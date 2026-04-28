#!/bin/bash

# --- Check for Root ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Try: sudo ./setup_smtp.sh" 
   exit 1
fi

# --- User Input ---
echo "------------------------------------------------"
echo "  FreePBX 17 Postfix SMTP Configuration Script  "
echo "------------------------------------------------"
read -p "Enter Relay Host IP: " RELAY_HOST
read -p "Enter SMTP Port (default 465): " SMTP_PORT
SMTP_PORT=${SMTP_PORT:-465}
read -p "Enter SMTP Username (e.g., support@domain.com): " SMTP_USER
read -s -p "Enter SMTP Password: " SMTP_PASS
echo ""
read -p "Enter Default Sender Email (e.g., support@famepbx.com): " SENDER_EMAIL
echo "------------------------------------------------"

# Define Paths
MAIN_CF="/etc/postfix/main.cf"
SASL_PASSWD="/etc/postfix/sasl/sasl_passwd"
GENERIC="/etc/postfix/generic"
CANONICAL="/etc/postfix/sender_canonical_maps"
HEADER="/etc/postfix/header_check"
ALIASES="/etc/aliases"

# --- Backup Existing Files ---
echo "Backing up existing configurations..."
for file in "$MAIN_CF" "$SASL_PASSWD" "$GENERIC" "$ALIASES"; do
    if [ -f "$file" ]; then
        cp "$file" "${file}.bak_$(date +%Y%m%d_%H%M%S)"
    fi
done

# --- Install Dependencies ---
echo "Installing libsasl2-modules..."
apt update && apt install -y libsasl2-modules bsd-mailx

# --- 1. Configure main.cf (Overwrite) ---
cat <<EOF > $MAIN_CF
smtpd_banner = \$myhostname ESMTP \$mail_name (Debian/GNU)
biff = no
append_dot_mydomain = no
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
mydestination = \$myhostname, localhost.\$mydomain, localhost
relayhost = [$RELAY_HOST]:$SMTP_PORT
mynetworks = 127.0.0.0/8
inet_interfaces = 127.0.0.1
recipient_delimiter = +
compatibility_level = 2
message_size_limit = 102400000
mailbox_size_limit = 102400000

# Enable SASL authentication
smtp_use_tls = yes
smtp_sasl_auth_enable = yes
smtp_sasl_security_options = noanonymous
smtp_sasl_password_maps = hash:$SASL_PASSWD
smtp_tls_security_level = encrypt
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
smtp_tls_wrappermode = yes
smtp_sasl_mechanism_filter = plain
sender_canonical_classes = envelope_sender, header_sender
sender_canonical_maps = regexp:$CANONICAL
smtp_header_checks = regexp:$HEADER
smtp_generic_maps = hash:$GENERIC
EOF

# --- 2. Configure sasl_passwd (Overwrite) ---
mkdir -p /etc/postfix/sasl
echo "[$RELAY_HOST]:$SMTP_PORT $SMTP_USER:$SMTP_PASS" > $SASL_PASSWD
chmod 600 $SASL_PASSWD
postmap $SASL_PASSWD

# --- 3. Configure generic (Overwrite) ---
cat <<EOF > $GENERIC
root $SENDER_EMAIL
root@localhost $SENDER_EMAIL
root@localhost.localdomain $SENDER_EMAIL
root@freepbx $SENDER_EMAIL
root@freepbx.localdomain $SENDER_EMAIL
asterisk $SENDER_EMAIL
asterisk@localhost $SENDER_EMAIL
asterisk@localhost.localdomain $SENDER_EMAIL
asterisk@freepbx $SENDER_EMAIL
asterisk@famecomputers.com $SENDER_EMAIL
vm@asterisk $SENDER_EMAIL
EOF
postmap $GENERIC

# --- 4. Configure sender_canonical_maps (Overwrite) ---
echo "/.+/ $SENDER_EMAIL" > $CANONICAL
postmap $CANONICAL

# --- 5. Configure header_check (Overwrite) ---
echo "/^From:.*$/ REPLACE From: $SENDER_EMAIL" > $HEADER

# --- 6. Update Aliases (Update only) ---
if grep -q "root:" $ALIASES; then
    sed -i "s|^root:.*|root: $SENDER_EMAIL|" $ALIASES
else
    echo "root: $SENDER_EMAIL" >> $ALIASES
fi
newaliases

# --- Finalize ---
echo "Restarting Postfix..."
systemctl restart postfix

echo "Configuration complete."
read -p "Would you like to send a test email to $SMTP_USER? (y/n): " CONFIRM
if [[ $CONFIRM == "y" ]]; then
    echo "Testing... Check /var/log/mail.log for status."
    echo "Test mail from FreePBX Postfix" | mail -s "Test Postfix" $SMTP_USER
fi
