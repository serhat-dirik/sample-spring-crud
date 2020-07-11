#!/bin/bash

while getopts d:s: option
do
case "${option}"
in
d) DEV_PROJECT=${OPTARG};;
s) STAGE_PROJECT=${OPTARG};;
esac
done

if [ -z "$DEV_PROJECT" ]
then
      echo "DEV_PROJECT name is empty. Please provide DEV_PROJECT name with -d parameter!";
      exit 1;
fi
if [ -z "$STAGE_PROJECT" ]
then
      echo "STAGE_PROJECT name is empty. Please provide STAGE_PROJECT name with -s parameter!";
      exit 1;
fi

echo  "DEV_PROJECT:" ${DEV_PROJECT}
echo  "STAGE_PROJECT:" ${STAGE_PROJECT}
echo "Creating projects...."
oc new-project ${STAGE_PROJECT}
oc new-project ${DEV_PROJECT}
oc project ${DEV_PROJECT}
echo "creating the java build config and the application from https://github.com/serhat-dirik/sample-spring-crud"
oc new-app java~https://github.com/serhat-dirik/sample-spring-crud --name sample-spring-crud -n ${DEV_PROJECT}
echo "Build Logs...."
oc logs -f bc/sample-spring-crud -n ${DEV_PROJECT}
echo "Set incremental build strategy as true"
oc patch bc/sample-spring-crud --type='json' --patch='[{"op":"add","path":"/spec/strategy/sourceStrategy/incremental","value":true}]' -n ${DEV_PROJECT}
echo "Exposing the service in dev project"
oc expose svc/sample-spring-crud -n ${DEV_PROJECT}

DEV_ROUTE=$(oc get route sample-spring-crud -o jsonpath='{.spec.host}' -n ${DEV_PROJECT})
echo "DEV Project route: http://"$DEV_ROUTE

echo "Tagging the latest image as stage-blue and stage-green for the initial deployment"
oc tag sample-spring-crud:latest sample-spring-crud:stage-blue -n ${DEV_PROJECT}
oc tag sample-spring-crud:latest sample-spring-crud:stage-green -n ${DEV_PROJECT}
echo "Adding the image-puller role to stage project default SA"
oc policy add-role-to-user system:image-puller system:serviceaccount:${STAGE_PROJECT}:default -n ${DEV_PROJECT}
echo "Creating Blue and Green services in the stage project"
oc new-app ${DEV_PROJECT}/sample-spring-crud:stage-blue --name sample-spring-crud-blue -n ${STAGE_PROJECT}
oc new-app ${DEV_PROJECT}/sample-spring-crud:stage-green --name sample-spring-crud-green -n ${STAGE_PROJECT}
echo "Creating sample-spring-crud default route connected to the Blue version"
oc expose svc sample-spring-crud-blue --name=sample-spring-crud -n ${STAGE_PROJECT}
STAGE_ROUTE=$(oc get route sample-spring-crud -o jsonpath='{.spec.host}' -n ${STAGE_PROJECT})
echo "STAGE Project route: http://" $STAGE_ROUTE
oc set route-backends sample-spring-crud  sample-spring-crud-blue=100 sample-spring-crud-green=0 -n ${STAGE_PROJECT}
oc set triggers dc/sample-spring-crud-green --from-image ${STAGE_PROJECT}/sample-spring-crud:stage-green --manual --containers sample-spring-crud-green -n ${STAGE_PROJECT}
oc set triggers dc/sample-spring-crud-blue --from-image ${STAGE_PROJECT}/sample-spring-crud:stage-blue --manual --containers sample-spring-crud-blue -n ${STAGE_PROJECT}

echo "Deploying Jenkins..."
oc new-app jenkins-ephemeral -n ${DEV_PROJECT}
oc logs dc/jenkins -f -n ${DEV_PROJECT}
# Grant Jenkins SA Access to Projects
echo "Granting the 'jenkins' SA to access the stage project..."
oc policy add-role-to-user edit system:serviceaccount:${DEV_PROJECT}:jenkins -n ${STAGE_PROJECT}
echo "Creating the pipeline build config"
oc new-app -n cicd -f cd-pipeline.yml --param DEV_PROJECT=${DEV_PROJECT} --param STAGE_PROJECT=${STAGE_PROJECT} -n ${DEV_PROJECT}
sleep 10
echo "Running the pipeline"
oc start-build bluegreen-pipeline -w
echo "Finished"
