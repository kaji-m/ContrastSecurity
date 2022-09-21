#!/bin/bash

if [ -z "$CONTRAST_BASEURL" -o -z "$CONTRAST_API_KEY" -o -z "$CONTRAST_USERNAME" -o -z "$CONTRAST_SERVICE_KEY" ]; then
    echo '環境変数が設定されていません。'
    echo 'CONTRAST_BASEURL       : https://(app|eval).contrastsecurity.com/Contrast'
    echo 'CONTRAST_API_KEY       : XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
    echo 'CONTRAST_USERNAME      : XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
    echo 'CONTRAST_SERVICE_KEY   : XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
    echo '!!注意!! USERNAME, SERVICE_KEYはSuperAdmin権限を持つユーザーとしてください。'
    exit 1
fi

BASEURL=$CONTRAST_BASEURL
API_KEY=$CONTRAST_API_KEY
USERNAME=$CONTRAST_USERNAME       # SuperAdminユーザー
SERVICE_KEY=$CONTRAST_SERVICE_KEY # SuperAdminユーザー
AUTHORIZATION=`echo "$(echo -n $USERNAME:$SERVICE_KEY | base64)"`
API_URL="${BASEURL}/api/ng"
GROUP_NAME=RulesAdminGroup

usage() {
  cat <<EOF
  Usage: $0 [options]
  -t|--target all|org|app
EOF
}

TARGET=
while getopts t-: opt; do
  optarg="${!OPTIND}"
  [[ "$opt" = - ]] && opt="-$OPTARG"
  case "-$opt" in
    -t|--target)
      TARGET="$optarg"
      shift
      ;;  
    --) 
      break
      ;;  
    -\?)
      exit 1
      ;;  
    --*)
      usage
      exit 1
      ;;  
  esac
done

if [ "${TARGET}" = "all" ]; then
    TARGET="ALL"
elif [ "${TARGET}" = "org" ]; then
    TARGET="ORG"
elif [ "${TARGET}" = "app" ]; then
    TARGET="APP"
else
    usage
    exit 1
fi

# 既存のグループを取得します。
rm -f ./groups.json
curl -X GET -sS -G \
     ${API_URL}/superadmin/ac/groups \
     -d expand=scopes,skip_links -d q=${GROUP_NAME} -d quickFilter=CUSTOM \
     -H "Authorization: ${AUTHORIZATION}" \
     -H "API-Key: ${API_KEY}" \
     -H 'Accept: application/json' -J -o groups.json

GRP_ID=`cat ./groups.json | jq -r --arg grp_name "${GROUP_NAME}" '.groups[] | select(.name==$grp_name) | .group_id'`

# 組織一覧を取得します。
rm -f ./organizaions.json
curl -X GET -sS -G \
     ${API_URL}/superadmin/organizations \
     -d base=base -d expand=skip_links \
     -H "Authorization: ${AUTHORIZATION}" \
     -H "API-Key: ${API_KEY}" \
     -H 'Accept: application/json' -J -o organizations.json

# 組織IDからjson配列を生成します。
SCOPES=
while read -r ORG_ID; do
    SCOPES=$SCOPES'{"org":{"id":"'$ORG_ID'","role":"rules_admin"},"app":{"exceptions":[],"role":"rules_admin"}},'
done < <(cat ./organizations.json | jq -r '.organizations[].organization_uuid')
SCOPES=`echo $SCOPES | sed "s/,$//"`
SCOPES="["$SCOPES"]"

# グループがない場合は作成、ある場合は組織の割当を更新します。
if [ "${GRP_ID}" = "" ]; then
    curl -X POST -sS \
        ${API_URL}/superadmin/ac/groups/organizational?expand=skip_links \
        -H "Authorization: ${AUTHORIZATION}" \
        -H "API-Key: ${API_KEY}" \
        -H "Content-Type: application/json" \
        -H 'Accept: application/json' \
        -d '{"name":"'$GROUP_NAME'","users":["'$USERNAME'"],"scopes":'$SCOPES'}'
else
    curl -X PUT -sS \
        ${API_URL}/superadmin/ac/groups/organizational/${GRP_ID}?expand=skip_links \
        -H "Authorization: ${AUTHORIZATION}" \
        -H "API-Key: ${API_KEY}" \
        -H "Content-Type: application/json" \
        -H 'Accept: application/json' \
        -d '{"name":"'$GROUP_NAME'","users":["'$USERNAME'"],"scopes":'$SCOPES'}'
fi

# 組織ごとのAPIキーを取得します。
rm -f orgid_apikey_map.txt
while read -r ORG_ID; do
    curl -X GET -sS -G \
         ${API_URL}/superadmin/users/${ORG_ID}/keys/apikey?expand=skip_links \
         -d base=base -d expand=skip_links \
         -H "Authorization: ${AUTHORIZATION}" \
         -H "API-Key: ${API_KEY}" \
         -H 'Accept: application/json' -J -o apikey.json
    GET_API_KEY=`cat ./apikey.json | jq -r '.api_key'`
    echo "$ORG_ID:$GET_API_KEY" >> orgid_apikey_map.txt
done < <(cat ./organizations.json | jq -r '.organizations[].organization_uuid')

if [ "${TARGET}" = "ALL" -o "${TARGET}" = "ORG" ]; then
    rm -f ./configs_default.csv
    while read -r RULE_NAME; do
        DEV_FLG=`cat ./default_rules.json | jq -r --arg rule_name "$RULE_NAME" '.rules[] | select(.name==$rule_name) | .enabled_dev'`
        QA_FLG=`cat ./default_rules.json | jq -r --arg rule_name "$RULE_NAME" '.rules[] | select(.name==$rule_name) | .enabled_qa'`
        PROD_FLG=`cat ./default_rules.json | jq -r --arg rule_name "$RULE_NAME" '.rules[] | select(.name==$rule_name) | .enabled_prod'`
        echo "${RULE_NAME},${DEV_FLG},DEVELOPMENT" >> ./configs_default.csv
        echo "${RULE_NAME},${QA_FLG},QA" >> ./configs_default.csv
        echo "${RULE_NAME},${PROD_FLG},PRODUCTION" >> ./configs_default.csv
    done < <(cat ./default_rules.json | jq -r '.rules[].name')
fi

if [ "${TARGET}" = "ALL" -o "${TARGET}" = "APP" ]; then
    rm -f ./configs_app.csv
    while read -r RULE_NAME; do
        DEV_FLG=`cat ./rules.json | jq -r --arg rule_name "$RULE_NAME" '.configs[] | select(.rule_name==$rule_name) | .dev_enabled'`
        QA_FLG=`cat ./rules.json | jq -r --arg rule_name "$RULE_NAME" '.configs[] | select(.rule_name==$rule_name) | .qa_enabled'`
        PROD_FLG=`cat ./rules.json | jq -r --arg rule_name "$RULE_NAME" '.configs[] | select(.rule_name==$rule_name) | .prod_enabled'`
        echo "${RULE_NAME},${DEV_FLG},${QA_FLG},${PROD_FLG}" >> ./configs_app.csv
    done < <(cat ./rules.json | jq -r '.configs[].rule_name')
fi

# 組織ごとにルールのon/offを反映していきます。
while read -r ORG_ID; do
    echo ""
    echo ${ORG_ID}
    ORG_API_KEY=`grep ${ORG_ID} ./orgid_apikey_map.txt | awk -F: '{print $2}'`

    if [ "${TARGET}" = "ALL" -o "${TARGET}" = "ORG" ]; then
        while read -r LINE; do
            NAME=`echo $LINE | awk -F, '{print $1}'`
            FLG=`echo $LINE | awk -F, '{print $2}'`
            ENVIRONMENT=`echo $LINE | awk -F, '{print $3}'`
            DATA=`jq --arg flg "${FLG}" --arg environment "${ENVIRONMENT}" -nc '{"enabled":$flg,"environment":$environment}'`
            echo $DATA
            curl -X PUT -sS \
                ${API_URL}/${ORG_ID}/rules/${NAME}/status?expand=skip_links \
                -H "Authorization: ${AUTHORIZATION}" \
                -H "API-Key: ${ORG_API_KEY}" \
                -H "Content-Type: application/json" \
                -H 'Accept: application/json' \
                -d "${DATA}"
            sleep 1
        done < ./configs_default.csv
    fi

    if [ "${TARGET}" = "ALL" -o "${TARGET}" = "APP" ]; then
        rm -f ./applications.json
        curl -X GET -sS \
             ${API_URL}/${ORG_ID}/applications?expand=skip_links \
             -H "Authorization: ${AUTHORIZATION}" \
             -H "API-Key: ${ORG_API_KEY}" \
             -H 'Accept: application/json' -J -o applications.json
        
        while read -r APP_ID; do
            echo ""
            APP_NAME=`cat ./applications.json | jq -r --arg app_id "$APP_ID" '.applications[] | select(.app_id==$app_id) | .name'`
            echo "${APP_ID} - ${APP_NAME}"
            while read -r LINE; do
                NAME=`echo $LINE | awk -F, '{print $1}'`
                DEV=`echo $LINE | awk -F, '{print $2}'`
                QA=`echo $LINE | awk -F, '{print $3}'`
                PROD=`echo $LINE | awk -F, '{print $4}'`
                DATA=`jq --arg name "${NAME}" --arg dev "${DEV}" --arg qa "${QA}" --arg prod "${PROD}" -nc '{rule_names:[$name],"dev_enabled":$dev,"qa_enabled":$qa,"prod_enabled":$prod}'`
                echo $DATA
                curl -X PUT -sS \
                    ${API_URL}/${ORG_ID}/assess/rules/configs/app/${APP_ID}/bulk?expand=skip_links \
                    -H "Authorization: ${AUTHORIZATION}" \
                    -H "API-Key: ${ORG_API_KEY}" \
                    -H "Content-Type: application/json" \
                    -H 'Accept: application/json' \
                    -d "${DATA}"
                sleep 1
            done < ./configs_app.csv
            sleep 1
        done < <(cat ./applications.json | jq -r '.applications[].app_id')
    fi
done < <(cat ./organizations.json | jq -r '.organizations[].organization_uuid')

exit 0
