#!/bin/bash

# install dialog package - update
sudo apt-get update
sudo apt-get install dialog -y

# Function to generate and show menu types/items
show_menu() {
    # Params for menu creation
    local Params=("$@")
    local TYPE=$1
    local TITLE=$2
    local MENU=" "
    if [ "$TYPE" = "checklist" ]; then
        MENU="Please pick your options"
    fi
    if [ "$TYPE" = "mixedform" ]; then
        MENU="Edit your server configuration"
    fi
    if [ "$TYPE" = "gauge" ]; then
        MENU="Waiting to complete the installation"
    fi

    # Get the rest parameters
    local ITEMS=("${Params[@]:2}")

    lines=$(dialog \
        --clear \
        --insecure \
        --backtitle "Odoo installation tool" \
        --title "$TITLE" \
        --$TYPE "$MENU" \
        15 60 8 \
        "${ITEMS[@]}" \
        2>&1 >/dev/tty)

    # Clear console contents
    clear

    result=()
    while read -r line; do
        result+=("${line:-""}")
    done <<<"${lines}"
}

show_message() {
    dialog --msgbox "$1" 20 50
    clear
}

activate_ssl_with_certbot() {
    if [ $ENABLE_SSL = "True" ]; then
        sudo apt install nginx -y
        cat <<EOF >~/odoo
server {
  listen 80;

  # set proper server name after domain set
  server_name $WEBSITE_NAME;

  # Add Headers for odoo proxy mode
  proxy_set_header X-Forwarded-Host \$host;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_set_header X-Real-IP \$remote_addr;
  add_header X-Frame-Options "SAMEORIGIN";
  add_header X-XSS-Protection "1; mode=block";
  proxy_set_header X-Client-IP \$remote_addr;
  proxy_set_header HTTP_X_FORWARDED_HOST \$remote_addr;

  #   odoo    log files
  access_log  /var/log/nginx/$OE_USER-access.log;
  error_log       /var/log/nginx/$OE_USER-error.log;

  #   increase    proxy   buffer  size
  proxy_buffers   16  64k;
  proxy_buffer_size   128k;

  proxy_read_timeout 900s;
  proxy_connect_timeout 900s;
  proxy_send_timeout 900s;

  #   force   timeouts    if  the backend dies
  proxy_next_upstream error   timeout invalid_header  http_500    http_502
  http_503;

  types {
    text/less less;
    text/scss scss;
  }

  #   enable  data    compression
  gzip    on;
  gzip_min_length 1100;
  gzip_buffers    4   32k;
  gzip_types  text/css text/less text/plain text/xml application/xml application/json application/javascript application/pdf image/jpeg image/png;
  gzip_vary   on;
  client_header_buffer_size 4k;
  large_client_header_buffers 4 64k;
  client_max_body_size 0;

  location / {
    proxy_pass    http://127.0.0.1:$OE_PORT;
    # by default, do not forward anything
    proxy_redirect off;
  }

  location /longpolling {
    proxy_pass http://127.0.0.1:$LONGPOLLING_PORT;
  }

  location ~* .(js|css|png|jpg|jpeg|gif|ico)$ {
    expires 2d;
    proxy_pass http://127.0.0.1:$OE_PORT;
    add_header Cache-Control "public, no-transform";
  }

  # cache some static data in memory for 60mins.
  location ~ /[a-zA-Z0-9_-]*/static/ {
    proxy_cache_valid 200 302 60m;
    proxy_cache_valid 404      1m;
    proxy_buffering    on;
    expires 864000;
    proxy_pass    http://127.0.0.1:$OE_PORT;
  }
}
EOF

        sudo mv ~/odoo /etc/nginx/sites-available/$WEBSITE_NAME
        sudo ln -s /etc/nginx/sites-available/$WEBSITE_NAME /etc/nginx/sites-enabled/$WEBSITE_NAME
        sudo rm /etc/nginx/sites-enabled/default
        sudo service nginx reload
        sudo su root -c "printf 'proxy_mode = True\n' >> $OE_HOME/config/odoo.conf"
    fi

    if [ $ENABLE_SSL = "True" ] && [ $ADMIN_EMAIL != "odoo@example.com" ] && [ $WEBSITE_NAME != "_" ]; then
        sudo apt-get update -y
        sudo apt install snapd -y
        sudo snap install core
        snap refresh core
        sudo apt install certbot python3-certbot-nginx -y
        sudo certbot --nginx -d $WEBSITE_NAME --noninteractive --agree-tos --email $ADMIN_EMAIL --redirect
        sudo service nginx reload
    else
        if $ADMIN_EMAIL = "odoo@example.com"; then
            show_message "Certbot does not support registering odoo@example.com. You should use real e-mail address."
        fi
        if $WEBSITE_NAME = "_"; then
            show_message "Website name is set as _. Cannot obtain SSL Certificate for _. You should use real website address."
        fi
    fi
}

print_specification() {
    echo "Odoo Server Specifications:"
    echo "Port: $OE_PORT"
    echo "User service: $OE_USER"
    echo "Configuraton file location: $OE_HOME/config/odoo.conf"
    echo "Logfile location: /var/log/odoo/odoo.log"
    echo "User PostgreSQL: $OE_USER"
    echo "Odoo Docker location: $OE_HOME/"
    echo "Custom Addons location: $OE_HOME/custom_module/"
    echo "Master Password (database): $OE_SUPERADMIN"
    echo "Start Odoo service: docker-compose up -d"
    echo "Stop Odoo service: docker-compose down"
    echo "Restart Odoo service: docker-compose restart"
    if [ $ENABLE_SSL = "True" ]; then
        echo "Nginx configuration file: /etc/nginx/sites-available/$WEBSITE_NAME"
    fi
}

odoo_install() {
    #--------------------------------------------------
    # Update Daemon configuration
    #--------------------------------------------------
    sed "s/#\$nrconf{restart} = 'i'/\$nrconf{restart} = 'a'/" /etc/needrestart/needrestart.conf >~/needrestart
    sudo mv ~/needrestart /etc/needrestart/needrestart.conf

    #--------------------------------------------------
    # Update Server
    #--------------------------------------------------
    sudo apt-get update

    #--------------------------------------------------
    # Install Docker
    #--------------------------------------------------
    sudo apt-get install docker docker-compose -y

    # Create Directory for log files
    sudo mkdir /var/log/odoo

    #--------------------------------------------------
    # Install ODOO
    #--------------------------------------------------
    # ---- Create custom module directory ----
    sudo mkdir "$OE_HOME"
    cd "$OE_HOME"
    sudo mkdir $OE_HOME/custom_module

    # ---- Create server config file ----
    sudo mkdir $OE_HOME/config
    sudo rm -f $OE_HOME/config/odoo.conf
    sudo touch $OE_HOME/config/odoo.conf

    sudo su root -c "printf '[options] \n; This is the password that allows database operations:\n' >> $OE_HOME/config/odoo.conf"
    sudo su root -c "printf 'admin_passwd = ${OE_SUPERADMIN}\n' >> $OE_HOME/config/odoo.conf"
    if [ $OE_VERSION ] >"11.0"; then
        sudo su root -c "printf 'http_port = ${OE_PORT}\n' >> $OE_HOME/config/odoo.conf"
    else
        sudo su root -c "printf 'xmlrpc_port = ${OE_PORT}\n' >> $OE_HOME/config/odoo.conf"
    fi
    sudo su root -c "printf 'logfile = /var/log/odoo/odoo.log\n' >> $OE_HOME/config/odoo.conf"
    sudo su root -c "printf 'addons_path=/mnt/extra-addons\n' >> $OE_HOME/config/odoo.conf"

    #--------------------------------------------------
    # Enable ssl with certbot
    #--------------------------------------------------
    activate_ssl_with_certbot

    #--------------------------------------------------
    # Config docker-compose
    #--------------------------------------------------
    cat <<EOF > ~/docker-compose.yml
version: '3.1'
services:
  odoo:
    image: odoo:$OE_VERSION
    env_file: .env
    depends_on:
      - postgres
    ports:
      - "$OE_PORT:8069"
      - "$LONGPOLLING_PORT:8072"
    volumes:
      - data:/var/lib/odoo
      - ./config:/etc/odoo
      - ./custom_module:/mnt/extra-addons
    restart: always
  postgres:
    image: postgres:15
    env_file: .env
    volumes:
      - db:/var/lib/pgsql/data/pgdata
    restart: always
volumes:
  data:
  db:
EOF
    sudo mv ~/docker-compose.yml $OE_HOME/docker-compose.yml

     #--------------------------------------------------
    # Env settings for docker service
    #--------------------------------------------------
    if [ ${#OE_SUPERADMIN} -le 1 ]; then
        OE_SUPERADMIN=`openssl rand -base64 12`
    fi

    cat <<EOF > ~/env
# postgresql environment variables
POSTGRES_DB=postgres
POSTGRES_PASSWORD=$OE_SUPERADMIN
POSTGRES_USER=$OE_USER
PGDATA=/var/lib/postgresql/data/pgdata

# odoo environment variables
HOST=postgres
USER=$OE_USER
PASSWORD=$OE_SUPERADMIN
EOF

    sudo mv ~/env $OE_HOME/.env
    echo -e "* Starting Odoo Service"
    sudo su root -c "docker-compose up -d"
    show_message "Installation completed"
    echo "-----------------------------------------------------------"
    echo "Done! The Odoo server is up and running."
    print_specification | tee $OE_HOME/server.info
    echo "-----------------------------------------------------------"

    echo "Server Specifications saved to $OE_HOME/server.info"
}

ODOO_INSTALL="True"
OE_USER="odoo"
OE_HOME="/$OE_USER"
# Set the default Odoo port (you still have to use -c /etc/odoo-server.conf for example to use this.)
OE_PORT="8069"
# Choose the Odoo version which you want to install. For example: 16.0, 15.0, 14.0 or saas-22. When using 'master' the master version will be installed.
# IMPORTANT! This script contains extra libraries that are specifically needed for Odoo 16.0
OE_VERSION="16.0"
# Set this to True if you want to install the Odoo enterprise version!
IS_ENTERPRISE="False"
# Set the superadmin password - if GENERATE_RANDOM_PASSWORD is set to "True" we will automatically generate a random password, otherwise we use this one
OE_SUPERADMIN=""

# Set the website name
WEBSITE_NAME="_"
# Set the default Odoo longpolling port (you still have to use -c /etc/odoo-server.conf for example to use this.)
LONGPOLLING_PORT="8072"
# Set to "True" to install certbot and have ssl enabled, "False" to use http
ENABLE_SSL="True"
# Provide Email to register ssl certificate
ADMIN_EMAIL="odoo@example.com"
# Provide Github account to Authenticate with Odoo EE github
GITHUB_USERNAME="odoo"
GITHUB_PASSWORD=""

CRACKED="False"

# Show menu for choosing installation options
# Checklist
OPTIONS=(
    1 "Odoo Installation (CE)" "on"
    2 "Enable SSL ( Domain mapped is Required )" "on"
)
# Get installation configuration options
show_menu "checklist" "Installation Options" "${OPTIONS[@]}"
[[ "${result[@]}" =~ "1" ]] && ODOO_INSTALL="True" || ODOO_INSTALL="False"
[[ "${result[@]}" =~ "2" ]] && ENABLE_SSL="True" || ENABLE_SSL="False"

if [ $ODOO_INSTALL = "True" ]; then
    # Choices ( menu )
    OPTIONS=(
        "16.0" "Odoo 16"
        "15.0" "Odoo 15"
        "14.0" "Odoo 14"
        "13.0" "Odoo 13"
    )
    show_menu "menu" "Odoo Version" "${OPTIONS[@]}"
    OE_VERSION="$result"

    # Mixedform
    OPTIONS=(
        "User:" 1 1 "$OE_USER" 1 25 35 0 0
        "Pwd (auto-gen if null):" 2 1 "$OE_SUPERADMIN" 2 25 35 0 1
        "Odoo port:" 3 1 "$OE_PORT" 3 25 35 0 0
        "Longpolling port:" 4 1 "$LONGPOLLING_PORT" 4 25 35 0 0
    )
    if [ $ENABLE_SSL = "True" ]; then
        OPTIONS+=(
            "Admin's Email:" 5 1 "$ADMIN_EMAIL" 5 25 35 0 0
            "Website:" 6 1 "example.com" 6 25 35 0 0
        )
    fi

    show_menu "mixedform" "Odoo Configurations" "${OPTIONS[@]}"
    OE_USER="${result[0]:="$OE_USER"}"
    OE_SUPERADMIN="${result[1]:="$OE_SUPERADMIN"}"
    OE_PORT="${result[2]:="$OE_PORT"}"
    LONGPOLLING_PORT="${result[3]:="$LONGPOLLING_PORT"}"
    ADMIN_EMAIL="${result[4]:="${ADMIN_EMAIL}"}"
    WEBSITE_NAME="${result[5]:="${WEBSITE_NAME}"}"
    GITHUB_USERNAME="${result[6]:="${GITHUB_USERNAME}"}"
    GITHUB_PASSWORD="${result[7]:="${GITHUB_PASSWORD}"}"

    OE_HOME="/$OE_USER"

    if [ ${#OE_USER} -ge 1 ]; then
        odoo_install
    fi
fi