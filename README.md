# MediTrack Cloud Deployment

Projet d'étude de cas GreenOps. Le site public est hébergé dans un bucket S3 privé diffusé par CloudFront avec OAC et HTTPS. L'EC2 et Ansible servent à démontrer l'automatisation d'un serveur Nginx. Aucune donnée de santé réelle.

## Préparation sous WSL Ubuntu ou Linux

Installer Terraform, AWS CLI v2, Ansible et Git selon les documentations officielles. Créer une identité IAM dédiée au projet et une politique limitée aux actions nécessaires VPC/EC2/S3/CloudFront ; demander une revue des permissions à un administrateur AWS. Ne pas publier de clés. Le test ListBuckets requiert une permission globale : un refus peut être voulu par la politique IAM.

    terraform version
    aws --version
    ansible --version
    aws configure --profile meditrack-deploy
    aws sts get-caller-identity --profile meditrack-deploy
    aws s3api list-buckets --profile meditrack-deploy
    ssh-keygen -t ed25519 -f ~/.ssh/meditrack -C meditrack

Copier terraform/terraform.tfvars.example en terraform/terraform.tfvars. Remplacer le chemin de clé publique et admin_cidr par l'IP publique personnelle suivie de /32. Les variables et l'état Terraform restent privés. Choisir une région AWS européenne prise en charge. Le déploiement AWS entraîne des frais.

## Exécution

Depuis le dossier terraform :

    terraform init
    terraform fmt -check
    terraform validate
    terraform plan -out=meditrack.tfplan
    terraform apply meditrack.tfplan
    terraform output
    BUCKET=$(terraform output -raw bucket_name)
    CDN_ID=$(terraform output -raw cloudfront_id)
    aws s3 sync ../site/ "s3://$BUCKET/" --delete --profile meditrack-deploy
    aws cloudfront create-invalidation --distribution-id "$CDN_ID" --paths '/*' --profile meditrack-deploy

Depuis la racine :

    ansible-galaxy collection install -r ansible/requirements.yml
    cp ansible/inventory.ini.example ansible/inventory.ini
    # Renseigner IP_EC2 et chemin de la clé privée, puis attendre que SSH réponde
    ansible -i ansible/inventory.ini web -m ping
    ansible-playbook -i ansible/inventory.ini ansible/playbook.yml -e admin_ip=VOTRE_IP_PUBLIQUE
    ansible-playbook -i ansible/inventory.ini ansible/playbook.yml -e admin_ip=VOTRE_IP_PUBLIQUE

La deuxième exécution est un contrôle d'idempotence : viser changed=0. Le code HTTP public de l'EC2 ne bénéficie pas du TLS CloudFront et ne doit servir qu'à la démonstration.

## Vérifications

Attendre que la distribution CloudFront soit déployée et que la copie S3 soit terminée. Depuis la racine :

    URL=$(terraform -chdir=terraform output -raw cloudfront_url)
    curl -I "$URL/"
    curl -I "http://${URL#https://}/"
    curl -fsS "$URL/contact.html" >/dev/null
    curl -I "http://$(terraform -chdir=terraform output -raw ec2_ip)/"

Attendus : 200 en HTTPS ; 301/302 avec Location HTTPS pour l'appel HTTP ; contact.html accessible ; EC2 HTTP 200. Conserver les sorties réelles, captures AWS et URL dans preuves/. Masquer clés et identifiants sensibles.

## Architecture, portée et fin de vie

CloudFront lit le bucket S3 privé via OAC ; le VPC n'héberge que l'EC2 de démonstration. Le bucket ne possède pas de point d'accès S3 website public. Une seule zone de disponibilité et une EC2 ne garantissent pas une haute disponibilité. Aucune supervision centralisée ni séparation test/production n'est livrée. L'infrastructure de démonstration ne prouve pas la conformité RGPD/HDS. Une exploitation de données de santé demanderait notamment un hébergement et un périmètre contractuel HDS appropriés, une analyse RGPD, journalisation, segmentation, sauvegardes et contrôle d'accès. Ne pas supprimer les ressources avant la fin de la correction ; ensuite vider le bucket, y compris les versions, et lancer terraform destroy.
