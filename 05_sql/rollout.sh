#!/bin/bash
set -e

PWD=$(get_pwd ${BASH_SOURCE[0]})

step="sql"

log_time "Step ${step} started"
printf "\n"

init_log ${step}
get_version


if [ "${RUN_QGEN}" == true ]; then
  log_time "Generate queries based on scale"
  cd ${PWD}
  ${PWD}/generate_queries.sh
  log_time "Finished generate queries based on scale"
fi

start_log

schema_name=${SCHEMA_NAME}
export schema_name
table_name="analyzedb"
export table_name

if [ "${RUN_ANALYZE}" == "true" ]; then

  dbname="$PGDATABASE"
  if [ "${dbname}" == "" ]; then
    dbname="${ADMIN_USER}"
  fi

  if [ "${PGPORT}" == "" ]; then
    export PGPORT=5432
  fi

  #Analyze schema using analyzedb
  if [ "$RUN_MODEL" == "local" ]; then
    log_time "analyzedb -d ${dbname} -s ${SCHEMA_NAME} --full -a"
    analyzedb -d ${dbname} -s ${SCHEMA_NAME} --full -a
  else
    log_time "psql -t -A ${PSQL_OPTIONS} -c \"select 'analyze ' ||schemaname||'.'||tablename||';' from pg_tables WHERE schemaname = '${SCHEMA_NAME}';\" |xargs -I {} -P 5 psql -a -A ${PSQL_OPTIONS} -c \"{}\""
    psql -t -A ${PSQL_OPTIONS} -c "select 'analyze ' ||schemaname||'.'||tablename||';' from pg_tables WHERE schemaname = '${SCHEMA_NAME}';" |xargs -I {} -P 5 psql -a -A ${PSQL_OPTIONS} -c "{}"
  fi


  #make sure root stats are gathered
  if [ "${VERSION}" == "gpdb_4_3" ] || [ "${VERSION}" == "gpdb_5" ] || [ "${VERSION}" == "gpdb_6" ]; then
    SQL_QUERY="select n.nspname, c.relname from pg_class c join pg_namespace n on c.relnamespace = n.oid left outer join (select starelid from pg_statistic group by starelid) s on c.oid = s.starelid join (select tablename from pg_partitions group by tablename) p on p.tablename = c.relname where n.nspname = '${SCHEMA_NAME}' and s.starelid is null order by 1, 2"
  else
    SQL_QUERY="select n.nspname, c.relname from pg_class c join pg_namespace n on c.relnamespace = n.oid left outer join (select starelid from pg_statistic group by starelid) s on c.oid = s.starelid join pg_partitioned_table p on p.partrelid = c.oid where n.nspname = '${SCHEMA_NAME}' and s.starelid is null order by 1, 2"
  fi

  for t in $(psql ${PSQL_OPTIONS} -v ON_ERROR_STOP=1 -q -t -A -c "${SQL_QUERY}"); do
    schema_name=$(echo ${t} | awk -F '|' '{print $1}')
    table_name=$(echo ${t} | awk -F '|' '{print $2}')
    echo "Missing root stats for ${schema_name}.${table_name}"
    SQL_QUERY="ANALYZE ROOTPARTITION ${schema_name}.${table_name}"
    log_time "psql ${PSQL_OPTIONS} -v ON_ERROR_STOP=1 -q -t -A -c \"${SQL_QUERY}\""
    psql ${PSQL_OPTIONS} -v ON_ERROR_STOP=1 -q -t -A -c "${SQL_QUERY}"
  done

else
  echo "AnalyzeDB Skipped..."
fi

tuples="-1"
print_log ${tuples}

rm -f ${TPC_DS_DIR}/log/*single.explain_analyze.log

if [ "${ON_ERROR_STOP}" == 0 ]; then
  set +e
fi

for i in ${PWD}/*.${BENCH_ROLE}.*.sql; do
  for _ in $(seq 1 ${SINGLE_USER_ITERATIONS}); do
    id=$(echo ${i} | awk -F '.' '{print $1}')
    export id
    schema_name=$(echo ${i} | awk -F '.' '{print $2}')
    export schema_name
    table_name=$(echo ${i} | awk -F '.' '{print $3}')
    export table_name
    
    start_log
    if [ "${EXPLAIN_ANALYZE}" == "false" ]; then
      log_time "psql ${PSQL_OPTIONS} -v ON_ERROR_STOP=1 -A -q -t -P pager=off -v EXPLAIN_ANALYZE=\"\" -f ${i} | wc -l"
      tuples=$(
        psql ${PSQL_OPTIONS} -v ON_ERROR_STOP=1 -A -q -t -P pager=off -v EXPLAIN_ANALYZE="" -f ${i} | wc -l
        exit ${PIPESTATUS[0]}
      )
      if [ $? != 0 ]; then
        tuples="-1"
      fi
    else
      myfilename=$(basename ${i})
      mylogfile=${TPC_DS_DIR}/log/${myfilename}.single.explain_analyze.log
      log_time "psql ${PSQL_OPTIONS} -v ON_ERROR_STOP=1 -A -q -t -P pager=off -v EXPLAIN_ANALYZE=\"EXPLAIN ANALYZE\" -f ${i} > ${mylogfile}"
      psql ${PSQL_OPTIONS} -v ON_ERROR_STOP=1 -A -q -t -P pager=off -v EXPLAIN_ANALYZE="EXPLAIN ANALYZE" -f ${i} > ${mylogfile}
      if [ $? != 0 ]; then
        tuples="-1"
      else
        tuples="0"
      fi
    fi
    print_log ${tuples}
    
    if [[ "${QUERY_INTERVAL}" -ne 0 ]]; then
      sleep ${QUERY_INTERVAL}
    fi
  done
done

log_time "Step ${step} finished"
printf "\n"