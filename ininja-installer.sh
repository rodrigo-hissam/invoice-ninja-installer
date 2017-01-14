#!/bin/bash

############################################
#	    Invoice Ninja Install Script       #
#     Script Created by Rodrigo Moreno     #
#    	 for https://mangolassi.it         #
############################################


# Ensure running as root
# composer should not be ran as root.
#if [[ $ EUID -ne 0 ]]; then
#  exec sudo "$0" "$@"
#fi
# Variables and inital setup
clear

name="ininja"
hostname="$(hostname)"
fqdn="$(hostname)"
tmp=/tmp/$name
logfile=/var/log/invoice-ninja-install.log
webdir=/var/www/html
user=$USER
app_key="$(< /dev/urandom tr -dc _A-Za-z-0-9 2>&1 | head -c32)"
app_user=${name}'_user'

spin[0]="-"
spin[1]="\\"
spin[2]="|"
spin[3]="/"

rm -rf ${tmp:?}
mkdir $tmp


cat << EOF

    ____                 _              _   ___         _          
   /  _/___ _   ______  (_)_______     / | / (_)___    (_)___ _    
   / // __ \ | / / __ \/ / ___/ _ \   /  |/ / / __ \  / / __  /    
 _/ // / / / |/ / /_/ / / /__/  __/  / /|  / / / / / / / /_/ /     
/___/_/ /_/|___/\____/_/\___/\___/  /_/ |_/_/_/ /_/_/ /\__,_/      
                                                 /___/             

EOF

echo " Welcome to the Invoice Ninja Installer for Ubuntu 16.10!"
echo ""
echo ""


#Getting your FQDN.
echo -n "  Q. What is the FQDN of your server? ($fqdn): "
read fqdn
if [ -z "$fqdn" ]; then
        fqdn="$(hostname --fqdn)"
fi
echo "     Setting to $fqdn"
echo ""

# Set your own passwords, or generate random ones?
until [[ $ans == "yes" ]] || [[ $ans == "no" ]]; do
echo -n "  Q. Do you want me to automatically create the invoice ninja database user password? (y/n) "
read setpw

case $setpw in
        [yY] | [yY][Ee][Ss] )
                mariadbuserpw="$(< /dev/urandom tr -dc _A-Za-z-0-9 2>&1 | head -c24)"
                ans="yes"
                ;;
        [nN] | [n|N][O|o] )
                echo -n  "  Q. Insert your mariadb database user password:"
                read -s mariadbuserpw
                echo ""
		ans="no"
                ;;
        *) 	echo "  Invalid answer. Please type y or n"
                ;;
esac
done

echo ""
echo  "* Making sure your Ubuntu install is updated (apt-get update)... ${spin[0]}"
echo ""
sudo apt-get update 

echo""
echo  " Upgrading your packages (apt-get upgrade)"
echo ""
sudo apt-get upgrade -y
echo ""



echo ""
echo ""
echo "* LEMP stack install and setup"
echo "------------------------------"

# NGINX
echo ""
echo "- Installing nginx " 
echo ""
sudo apt-get install nginx -y
echo ""



# MARIADB
echo ""
echo ""
echo  "- Installing MariaDB "
sudo apt-get install software-properties-common -y
sudo apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0xF1656F24C74CD1D8
sudo add-apt-repository 'deb [arch=amd64,i386] http://mirror.jmu.edu/pub/mariadb/repo/10.1/ubuntu yakkety main'
sudo apt-get update
sudo apt-get install mariadb-server -y
echo ""
echo ""
echo "- Hardening mariadb installation"
mysql_secure_installation
echo ""
echo "Create the database for Invoice Ninja..."
echo -n "Please enter your MARIADB root password: "
read -s mariadbrootpw
mysql -uroot -p${mariadbrootpw} -e "CREATE DATABASE ${name};"
mysql -uroot -p${mariadbrootpw} -e "CREATE user ${name}_user@localhost IDENTIFIED BY '${mariadbuserpw}';"
mysql -uroot -p${mariadbrootpw} -e "GRANT ALL PRIVILEGES ON ${name}.* TO '${name}_user'@'localhost';"
mysql -uroot -p${mariadbrootpw} -e "FLUSH PRIVILEGES;"



#PHP and extras
echo ""
echo ""
echo "- Installing and setting up PHP7.0 and its extensions "
sudo apt-get install curl wget php7.0 php7.0-fpm php7.0-mysql php7.0-mcrypt php7.0-gd php7.0-curl php7.0-mbstring php7.0-zip php7.0-gmp php7.0-xml -y
sudo sed -i.bak 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/g' /etc/php/7.0/fpm/php.ini
sudo phpenmod -v 7.0 mcrypt
sudo systemctl restart php7.0-fpm
cd $tmp
echo ""
echo ""
curl -sS https://getcomposer.org/installer | php
sudo mv composer.phar /usr/local/bin/composer
 

#Invoice Ninja
echo ""
echo  "- Installing git and cloning the Invoice Ninja repo "
sudo apt-get install git
git clone https://github.com/hillelcoren/invoice-ninja.git  $name 
sudo mv $name $webdir
sudo chown -R $user:$user $webdir/$name
cd $webdir/$name


#
echo ""
echo "---- Downloading Invoice Ninja Dependencies "
composer install --no-dev -o

# Setting env variables
echo ""
echo "- Setting up .env file"
mv .env.example .env
sudo sed -i.bak "s/DB_DATABASE=ninja/DB_DATABASE=${name}/g" .env
sudo sed -i.bak "s/DB_USERNAME=ninja/DB_USERNAME=${app_user}/g" .env
sudo sed -i.bak "s/DB_PASSWORD=ninja/DB_PASSWORD=${mariadbuserpw}/g" .env

sudo sed -i.bak "s/APP_UR:L=http:\/\/ninja.dev/APP_URL=${fqdn}/g" .env

# Running db migrations and seeding the db
echo ""
echo "- Running invoice ninja db migration, this will take a while"
php artisan migrate
php artisan db:seed

php artisan key:generate


# Creating a new PHP-FPM pool for our user
echo ""
echo "- Creating a new PHP-FPM pool"
cat  > $tmp/$user.conf << EOF
[$user]
user = $user
group = $user
listen = /var/run/php/php7.0-fpm-$user.sock
listen.owner = $user
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 10s;  
pm.max_requests = 200  
chdir = /  
EOF

# Moving the pool conf and restarting the service
sudo mv $tmp/$user.conf /etc/php/7.0/fpm/pool.d/
sudo systemctl restart php7.0-fpm.service 

echo ""
echo "# Creating self signed certificate and nginx config"
echo""
# Create the SSL self sigend certificate
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/nginx-selfsigned.key -out /etc/ssl/certs/nginx-selfsigned.crt
# Diffie-Hellman group, used in negotiating Perfect Forward Secrecy with clients.
sudo openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048

cat > $tmp/ssl.conf << EOF
server {
    listen 443 http2 ssl;
    listen [::]:443 http2 ssl;

    server_name $fqdn;

    ssl_certificate /etc/ssl/certs/nginx-selfsigned.crt;
    ssl_certificate_key /etc/ssl/private/nginx-selfsigned.key;
    ssl_dhparam /etc/ssl/certs/dhparam.pem;

    ########################################################################
    # from https://cipherli.st/                                            #
    # and https://raymii.org/s/tutorials/Strong_SSL_Security_On_nginx.html #
    ########################################################################

    ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
    ssl_prefer_server_ciphers on;
    ssl_ciphers "EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH";
    ssl_ecdh_curve secp384r1;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;
    # Disable preloading HSTS for now.  You can use the commented out header line that includes
    # the "preload" directive if you understand the implications.
    #add_header Strict-Transport-Security "max-age=63072000; includeSubdomains; preload";
    add_header Strict-Transport-Security "max-age=63072000; includeSubdomains";
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;

    ##################################
    # END https://cipherli.st/ BLOCK #
    ##################################

    charset utf-8;

    root /var/www/html/$name/public;

    index index.html index.htm index.php;

    location / {
    	try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log  /var/log/nginx/ininja.access.log;
    error_log   /var/log/nginx/ininja.error.log;

    sendfile off;

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/var/run/php/php7.0-fpm-$user.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
    }

    location ~ /\.ht {
        deny all;
    }
}

server {
        listen 80;
        server_name 192.168.2.26;
        return  301 https://\$server_name\$request_uri;
}
EOF

sudo mv $tmp/ssl.conf /etc/nginx/conf.d/

sudo systemctl restart php7.0-fpm.service 
sudo systemctl restart nginx.service

echo "ALL DONE!!! Point your web browser to ${fqdn} and complete the setup"
