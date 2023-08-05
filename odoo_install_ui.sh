#!/bin/bash

# Function to generate and show menu types/items
show_menu(){
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
    done <<< "${lines}"
}

show_message() {
    dialog --msgbox "$1" 20 50
    clear
}

activate_ssl_with_certbot(){
    if [ $ENABLE_SSL = "True" ]; then
        sudo apt install nginx -y
        cat <<EOF > ~/odoo
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
        sudo su root -c "printf 'proxy_mode = True\n' >> /etc/${OE_USER}.conf"
    fi
    
    if [ $INSTALL_NGINX = "True" ] && [ $ENABLE_SSL = "True" ] && [ $ADMIN_EMAIL != "odoo@example.com" ]  && [ $WEBSITE_NAME != "_" ];then
        sudo apt-get update -y
        sudo apt install snapd -y
        sudo snap install core; snap refresh core
        sudo apt install certbot python3-certbot-nginx -y
        sudo certbot --nginx -d $WEBSITE_NAME --noninteractive --agree-tos --email $ADMIN_EMAIL --redirect
        sudo service nginx reload
    else
        if $ADMIN_EMAIL = "odoo@example.com";then
            show_message "Certbot does not support registering odoo@example.com. You should use real e-mail address."
        fi
        if $WEBSITE_NAME = "_";then
            show_message "Website name is set as _. Cannot obtain SSL Certificate for _. You should use real website address."
        fi
    fi
}

install_enterprise_dependencies() {
    source $OE_HOME/$OE_USER-venv/bin/activate
    sudo pip3 install psycopg2-binary pdfminer.six -y
    sudo ln -s /usr/bin/nodejs /usr/bin/node
    sudo su $OE_USER -c "mkdir $OE_HOME/enterprise"
    sudo su $OE_USER -c "mkdir $OE_HOME/enterprise/addons"
    deactivate
    
    if [ "$CRACKED" = "False" ]; then
        GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://$GITHUB_USERNAME:$GITHUB_PASSWORD@github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
        while [[ $GITHUB_RESPONSE == *"Authentication"* ]]; do
            show_message "Your authentication with Github has failed! Please try again."
            OPTIONS+=(
                "Github username:" 1 1 "" 1 25 35 0 0
                "Github password:" 2 1 "" 2 25 35 0 1
            )
            show_menu "mixedform" "GITHUB AUTHENTICATE" "${OPTIONS[@]}"
            GITHUB_USERNAME="${result[0]:="${GITHUB_USERNAME}"}"
            GITHUB_PASSWORD="${result[1]:="${GITHUB_PASSWORD}"}"
            GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://$GITHUB_USERNAME:$GITHUB_PASSWORD@github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
        done
    fi
    
    sudo pip3 install num2words ofxparse dbfread ebaysdk firebase_admin -y
    sudo pip3 install pyopenssl==22.1.0 -y
    sudo npm install -g less
    sudo npm install -g less-plugin-clean-css
}

odoo_install(){
    #--------------------------------------------------
    # Update Server
    #--------------------------------------------------
    # universe package is for Ubuntu 18.x
    sudo add-apt-repository universe -y
    # libpng12-0 dependency for wkhtmltopdf for older Ubuntu versions
    sudo add-apt-repository "deb http://mirrors.kernel.org/ubuntu/ xenial main" -y
    sudo apt-get update
    sudo apt-get upgrade -y
    sudo apt-get install libpq-dev -y
    
    #--------------------------------------------------
    # Install Dependencies
    #--------------------------------------------------
    sudo apt-get install python3 python3-pip python3-venv -y
    sudo apt-get install git python3-cffi build-essential wget python3-dev \
    python3-venv python3-wheel libxslt-dev libzip-dev libldap2-dev libsasl2-dev \
    python3-setuptools node-less libpng-dev libjpeg-dev gdebi -y
    
    sudo apt-get install nodejs npm -y
    sudo npm install -g rtlcss
    
    #--------------------------------------------------
    # Install PostgreSQL Server
    #--------------------------------------------------
    sudo apt-get install postgresql postgresql-server-dev-all -y
    sudo su - postgres -c "createuser -s $OE_USER" 2> /dev/null || true
    
    #--------------------------------------------------
    # Install Wkhtmltopdf
    #--------------------------------------------------
    # Check if the operating system is Ubuntu 22.04
    if [[ $(lsb_release -r -s) == "22.04" ]]; then
        WKHTMLTOX_X64="https://packages.ubuntu.com/jammy/wkhtmltopdf"
        WKHTMLTOX_X32="https://packages.ubuntu.com/jammy/wkhtmltopdf"
        #No Same link works for both 64 and 32-bit on Ubuntu 22.04
    else
        # For older versions of Ubuntu
        WKHTMLTOX_X64="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.$(lsb_release -c -s)_amd64.deb"
        WKHTMLTOX_X32="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.$(lsb_release -c -s)_i386.deb"
    fi
    
    if [ "`getconf LONG_BIT`" == "64" ];then
        _url=$WKHTMLTOX_X64
    else
        _url=$WKHTMLTOX_X32
    fi
    sudo wget $_url
    
    if [[ $(lsb_release -r -s) == "22.04" ]]; then
        # Ubuntu 22.04 LTS
        sudo apt install wkhtmltopdf -y
    else
        # For older versions of Ubuntu
        sudo gdebi --n `basename $_url`
    fi
    
    sudo ln -s /usr/local/bin/wkhtmltopdf /usr/bin
    sudo ln -s /usr/local/bin/wkhtmltoimage /usr/bin
    
    sudo adduser --system --quiet --shell=/bin/bash --home=$OE_HOME --gecos $OE_USER --group $OE_USER
    sudo adduser $OE_USER sudo
    
    # Create Directory for log files
    sudo mkdir /var/log/odoo
    sudo chown $OE_USER:$OE_USER /var/log/odoo
    
    #--------------------------------------------------
    # Install ODOO
    #--------------------------------------------------
    sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/odoo $OE_HOME/$OE_USER
    
    # ---- Install ODdoo requirements ----
    python3 -m venv $OE_HOME/$OE_USER-venv
    source $OE_HOME/$OE_USER-venv/bin/activate
    pip3 install wheel
    pip3 install -r $OE_HOME/$OE_USER/requirements.txt
    deactivate
    
    if [ $IS_ENTERPRISE = "True" ] || [ $CRACKED = "True" ]; then
        # Odoo Enterprise install!
        install_enterprise_dependencies
    fi
    
    # ---- Create custom module directory ----
    sudo mkdir $OE_HOME/custom_module
    # ---- Setting permissions on home folder ----
    sudo chown $OE_USER:$OE_USER $OE_HOME
    
    # ---- Create server config file ----
    sudo touch /etc/${OE_USER}.conf
    sudo su root -c "printf '[options] \n; This is the password that allows database operations:\n' >> /etc/${OE_USER}.conf"
    sudo su root -c "printf 'admin_passwd = ${OE_SUPERADMIN}\n' >> /etc/${OE_USER}.conf"
    if [ $OE_VERSION > "11.0" ];then
        sudo su root -c "printf 'http_port = ${OE_PORT}\n' >> /etc/${OE_USER}.conf"
    else
        sudo su root -c "printf 'xmlrpc_port = ${OE_PORT}\n' >> /etc/${OE_USER}.conf"
    fi
    sudo su root -c "printf 'logfile = /var/log/odoo/${OE_USER}.log\n' >> /etc/${OE_USER}.conf"
    if [ $IS_ENTERPRISE = "True" ]; then
        sudo su root -c "printf 'addons_path=${OE_HOME}/enterprise/addons,${OE_HOME}/${OE_USER}/addons,${OE_HOME}/custom_module\n' >> /etc/${OE_USER}.conf"
    else
        sudo su root -c "printf 'addons_path=${OE_HOME}/${OE_USER}/addons,${OE_HOME}/custom_module\n' >> /etc/${OE_USER}.conf"
    fi
    
    sudo chown $OE_USER:$OE_USER /etc/${OE_USER}.conf
    sudo chmod 640 /etc/${OE_USER}.conf
    
    #--------------------------------------------------
    # Enable ssl with certbot
    #--------------------------------------------------
    activate_ssl_with_certbot
    
    # ---- Create Odoo Systemd Unit file ----
    cat <<EOF > ~/odoo
[Unit]
    Description=$OE_USER
    Requires=postgresql.service
    After=network.target postgresql.service

[Service]
    Type=simple
    SyslogIdentifier=$OE_USER
    PermissionsStartOnly=true
    User=$OE_USER
    Group=$OE_USER
    Restart=on-failure
    ExecStart=$OE_HOME/$OE_USER-venv/bin/python3 $OE_HOME/$OE_USER/odoo-bin -c /etc/${OE_USER}.conf
    StandardOutput=journal+console

[Install]
    WantedBy=default.target
EOF
    sudo mv ~/odoo /etc/systemd/system/$OE_USER.service
    sudo systemctl daemon-reload
    sudo systemctl enable $OE_USER
    sudo systemctl start $OE_USER
    
    show_message "Installation completed"
    
    echo -e "* Starting Odoo Service"
    sudo su root -c "service $OE_USER start"
    echo "-----------------------------------------------------------"
    echo "Done! The Odoo server is up and running. Specifications:"
    echo "Port: $OE_PORT"
    echo "User service: $OE_USER"
    echo "Configuraton file location: /etc/${OE_USER}.conf"
    echo "Logfile location: /var/log/odoo/$OE_USER"
    echo "User PostgreSQL: $OE_USER"
    echo "Code location: $OE_USER"
    echo "Addons folder: $OE_USER/custom_module/"
    echo "Password superadmin (database): $OE_SUPERADMIN"
    echo "Start Odoo service: sudo service $OE_USER start"
    echo "Stop Odoo service: sudo service $OE_USER stop"
    echo "Restart Odoo service: sudo service $OE_USER restart"
    echo "Status Odoo service: sudo service $OE_USER status"
    if [ $ENABLE_SSL = "True" ]; then
        echo "Nginx configuration file: /etc/nginx/sites-available/$WEBSITE_NAME"
    fi
    echo "-----------------------------------------------------------"
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
OE_SUPERADMIN="admin"

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
    3 "Odoo Enterprise" "off"
    4 "Odoo Enterprise Crack" "off"
)
# Get installation configuration options
show_menu "checklist" "Installation Options" "${OPTIONS[@]}"
[[ "${result[@]}" =~ "1" ]] && ODOO_INSTALL="True" || ODOO_INSTALL="False"
[[ "${result[@]}" =~ "2" ]] && ENABLE_SSL="True" || ENABLE_SSL="False"
[[ "${result[@]}" =~ "3" ]] && IS_ENTERPRISE="True" || IS_ENTERPRISE="False"
[[ "${result[@]}" =~ "4" ]] && CRACKED="True" || CRACKED="False"

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
        "User/Group:" 1 1 "$OE_USER" 1 25 35 0 0
        "SU Pwd(df:admin):" 2 1 "$OE_SUPERADMIN" 2 25 35 0 1
        "Odoo port:" 3 1 "$OE_PORT" 3 25 35 0 0
        "Longpolling port:" 4 1 "$LONGPOLLING_PORT" 4 25 35 0 0
    )
    if [ $ENABLE_SSL = "True" ]; then
        OPTIONS+=(
            "Admin's Email:" 5 1 "$ADMIN_EMAIL" 5 25 35 0 0
            "Website:" 6 1 "example.com" 6 25 35 0 0
        )
    fi
    
    if [ $IS_ENTERPRISE = "True" ]; then
        OPTIONS+=(
            "Github username:" 7 1 "" 7 25 35 0 0
            "Github password:" 8 1 "" 8 25 35 0 1
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
    
    odoo_install
fi
