#!/bin/bash

DOCKER_TAG="$1"

# Clean
rm -f ./helm-chart/values.yaml
rm -rf ./helm-chart/templates

# Install kompose
LATEST_KOMPOSE="$(git ls-remote --tags https://github.com/kubernetes/kompose.git | cut -d/ -f3 | grep -viE -- 'rc|b' | sort -V | tail -1)"
curl -L https://github.com/kubernetes/kompose/releases/download/"$LATEST_KOMPOSE"/kompose-linux-amd64 -o kompose
chmod +x kompose
sudo mv ./kompose /usr/local/bin/kompose

set -ex

# Conversion of docker-compose
cd manual-install
cp latest.yml latest.yml.backup
cp sample.conf /tmp/
sed -i 's|^|export |' /tmp/sample.conf
# shellcheck disable=SC1091
source /tmp/sample.conf
rm /tmp/sample.conf
sed -i "s|\${IMAGE_TAG}|$DOCKER_TAG\${IMAGE_TAG}|" latest.yml
sed -i "s|\${APACHE_IP_BINDING}|$APACHE_IP_BINDING|" latest.yml
sed -i "s|\${APACHE_PORT}:\${APACHE_PORT}/|$APACHE_PORT:$APACHE_PORT/|" latest.yml
sed -i "s|\${TALK_PORT}:\${TALK_PORT}/|$TALK_PORT:$TALK_PORT/|g" latest.yml
sed -i "s|- \${APACHE_PORT}|- $APACHE_PORT|" latest.yml
sed -i "s|- \${TALK_PORT}|- $TALK_PORT|" latest.yml
sed -i "s|\${NEXTCLOUD_DATADIR}|$NEXTCLOUD_DATADIR|" latest.yml
sed -i "/NEXTCLOUD_DATADIR/d" latest.yml
sed -i "/\${NEXTCLOUD_MOUNT}/d" latest.yml
sed -i "/^volumes:/a\ \ nextcloud_aio_nextcloud_trusted_cacerts:\n \ \ \ \ name: nextcloud_aio_nextcloud_trusted_cacerts" latest.yml
sed -i "s|\${NEXTCLOUD_TRUSTED_CACERTS_DIR}:|nextcloud_aio_nextcloud_trusted_cacerts:|g#" latest.yml
sed -i 's|\${|{{ .Values.|g' latest.yml
sed -i 's|}| }}|g' latest.yml
cat latest.yml
kompose convert -c -f latest.yml
cd latest

mv ./templates/manual-install-nextcloud-aio-networkpolicy.yaml ./templates/nextcloud-aio-networkpolicy.yaml
# shellcheck disable=SC1083
find ./ -name '*networkpolicy.yaml' -exec sed -i "s|manual-install-nextcloud-aio|nextcloud-aio|" \{} \; 
cat << EOL > /tmp/initcontainers
      initContainers:
        - name: init-volumes
          image: alpine
          command:
            - chmod
            - "777"
          volumeMountsInitContainer:
EOL
cat << EOL > /tmp/initcontainers.database
      initContainers:
        - name: init-volumes
          image: alpine
          command:
            - chown
            - 999:999
          volumeMountsInitContainer:
EOL
# shellcheck disable=SC1083
DEPLOYMENTS="$(find ./ -name '*deployment.yaml')"
mapfile -t DEPLOYMENTS <<< "$DEPLOYMENTS"
for variable in "${DEPLOYMENTS[@]}"; do
    if grep -q volumeMounts "$variable"; then
        if ! echo "$variable" | grep -q database; then
            sed -i "/^    spec:/r /tmp/initcontainers" "$variable"
        else
            sed -i "/^    spec:/r /tmp/initcontainers.database" "$variable"
        fi
        volumeNames="$(grep -A1 mountPath "$variable" | grep -v mountPath | sed 's|.*name: ||' | sed '/^--$/d')"
        mapfile -t volumeNames <<< "$volumeNames"
        for volumeName in "${volumeNames[@]}"; do
            sed -i "/^.*volumeMountsInitContainer:/i\ \ \ \ \ \ \ \ \ \ \ \ - /$volumeName" "$variable"
            sed -i "/volumeMountsInitContainer:/a\ \ \ \ \ \ \ \ \ \ \ \ - name: $volumeName\n\ \ \ \ \ \ \ \ \ \ \ \ \ \ mountPath: /$volumeName" "$variable"
        done
        sed -i "s|volumeMountsInitContainer|volumeMounts|" "$variable"
        if grep -q claimName "$variable"; then
            claimNames="$(grep claimName "$variable")"
            mapfile -t claimNames <<< "$claimNames"
            for claimName in "${claimNames[@]}"; do
                if grep -A1 "^$claimName$" "$variable" | grep -q "readOnly: true"; then
                    sed -i "/^$claimName$/{n;d}" "$variable"
                fi
            done
        fi
    fi
done
# shellcheck disable=SC1083
find ./ -name '*service.yaml' -exec sed -i "/^status:/,$ d" \{} \; 
# shellcheck disable=SC1083
find ./ -name '*deployment.yaml' -exec sed -i "s|manual-install-nextcloud-aio|nextcloud-aio|" \{} \; 
# shellcheck disable=SC1083
find ./ -name '*persistentvolumeclaim.yaml' -exec sed -i "s|ReadOnlyMany|ReadWriteOnce|" \{} \;   
# shellcheck disable=SC1083
find ./ -name '*persistentvolumeclaim.yaml' -exec sed -i "/accessModes:/i\ \ {{- if .Values.STORAGE_CLASS }}" \{} \;  
# shellcheck disable=SC1083
find ./ -name '*persistentvolumeclaim.yaml' -exec sed -i "/accessModes:/i\ \ storageClassName: {{ .Values.STORAGE_CLASS }}" \{} \; 
# shellcheck disable=SC1083
find ./ -name '*persistentvolumeclaim.yaml' -exec sed -i "/accessModes:/i\ \ {{- end }}" \{} \; 
# shellcheck disable=SC1083
find ./ -name '*deployment.yaml' -exec sed -i "/restartPolicy:/d" \{} \; 
# shellcheck disable=SC1083
find ./ -name '*apache*' -exec sed -i "s|$APACHE_IP_BINDING|{{ .Values.APACHE_IP_BINDING }}|" \{} \;  
# shellcheck disable=SC1083
find ./ -name '*apache*' -exec sed -i "s|$APACHE_PORT|{{ .Values.APACHE_PORT }}|" \{} \;  
# shellcheck disable=SC1083
find ./ -name '*talk*' -exec sed -i "s|$TALK_PORT|{{ .Values.TALK_PORT }}|" \{} \; 
# shellcheck disable=SC1083
find ./ -name '*.yaml' -exec sed -i "s|'{{|\"{{|g;s|}}'|}}\"|g" \{} \; 
# shellcheck disable=SC1083
find ./ -name '*.yaml' -exec sed -i "/type: Recreate/d" \{} \; 
# shellcheck disable=SC1083
find ./ -name '*.yaml' -exec sed -i "/strategy:/d" \{} \; 
# shellcheck disable=SC1083
find ./ \( -not -name '*service.yaml' -name '*.yaml' \) -exec sed -i "/^status:/d" \{} \; 
# shellcheck disable=SC1083
find ./ \( -not -name '*persistentvolumeclaim.yaml' -name '*.yaml' \) -exec sed -i "/resources:/d" \{} \; 
# shellcheck disable=SC1083
find ./ -name '*.yaml' -exec sed -i "/creationTimestamp: null/d" \{} \; 
VOLUMES="$(find ./ -name '*persistentvolumeclaim.yaml' | sed 's|-persistentvolumeclaim.yaml||g;s|.*nextcloud-aio-||g')"
mapfile -t VOLUMES <<< "$VOLUMES"
for variable in "${VOLUMES[@]}"; do
    name="$(echo "$variable" | sed 's|-|_|g' | tr '[:lower:]' '[:upper:]')_STORAGE_SIZE"
    VOLUME_VARIABLE+=("$name")
    # shellcheck disable=SC1083
    find ./ -name "*nextcloud-aio-$variable-persistentvolumeclaim.yaml" -exec sed -i "s|storage: 100Mi|storage: {{ .Values.$name }}|" \{} \; 
done

cd ../
mkdir -p ../helm-chart/
rm latest/Chart.yaml
rm latest/README.md
mv latest/* ../helm-chart/
rm -r latest
rm latest.yml
mv latest.yml.backup latest.yml

# Get version of AIO
AIO_VERSION="$(grep 'Nextcloud AIO ' ../php/templates/containers.twig | grep -oP '[0-9]+.[0-9]+.[0-9]+')"
sed -i "s|^version:.*|version: $AIO_VERSION|" ../helm-chart/Chart.yaml

# Conversion of sample.conf
cp sample.conf /tmp/
sed -i 's|"||g' /tmp/sample.conf
sed -i 's|=|: |' /tmp/sample.conf
sed -i 's|= |: |' /tmp/sample.conf
sed -i '/^NEXTCLOUD_DATADIR/d' /tmp/sample.conf
sed -i '/^NEXTCLOUD_MOUNT/d' /tmp/sample.conf
sed -i '/_ENABLED.*/s/ yes / "yes" /' /tmp/sample.conf
sed -i 's|^NEXTCLOUD_TRUSTED_CACERTS_DIR: .*|NEXTCLOUD_TRUSTED_CACERTS_DIR:        # Setting this to any value allows to automatically import root certificates into the Nextcloud container|' /tmp/sample.conf
# shellcheck disable=SC2129
echo 'STORAGE_CLASS:        # By setting this, you can adjust the storage class for your volumes' >> /tmp/sample.conf
for variable in "${VOLUME_VARIABLE[@]}"; do
    echo "$variable: 1Gi       # You can change the size of the $(echo "$variable" | sed 's|_STORAGE_SIZE||;s|_|-|g' | tr '[:upper:]' '[:lower:]') volume that default to 1Gi with this value" >> /tmp/sample.conf
done
mv /tmp/sample.conf ../helm-chart/values.yaml

ENABLED_VARIABLES="$(grep -oP '^[A-Z]+_ENABLED' ../helm-chart/values.yaml)"
mapfile -t ENABLED_VARIABLES <<< "$ENABLED_VARIABLES"

cd ../helm-chart/
for variable in "${ENABLED_VARIABLES[@]}"; do
    name="$(echo "$variable" | sed 's|_ENABLED||g' | tr '[:upper:]' '[:lower:]')"
    # shellcheck disable=SC1083
    find ./ -name "*nextcloud-aio-$name-deployment.yaml" -exec sed -i "1i\\{{- if eq .Values.$variable \"yes\" }}" \{} \; 
    # shellcheck disable=SC1083
    find ./ -name "*nextcloud-aio-$name-deployment.yaml" -exec sed -i "$ a {{- end }}" \{} \; 
    # shellcheck disable=SC1083
    find ./ -name "*nextcloud-aio-$name-service.yaml" -exec sed -i "1i\\{{- if eq .Values.$variable \"yes\" }}" \{} \; 
    # shellcheck disable=SC1083
    find ./ -name "*nextcloud-aio-$name-service.yaml" -exec sed -i "$ a {{- end }}" \{} \; 
done

chmod 777 -R ./

set +ex
