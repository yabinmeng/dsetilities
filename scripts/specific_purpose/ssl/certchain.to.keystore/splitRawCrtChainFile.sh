#! /bin/bash

usage() {
   echo
   echo "Usage: splitRawCrtFile.sh [-h | <example_raw_cert_chain_file> <node_name>]"
   echo
}

if [[ $1 == "-h" || $# -ne 2 ]]; then
   usage
   exit 10
fi

# Node key
cat $1 | awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' > $2.key

ALL_CERTS=`openssl crl2pkcs7 -nocrl -certfile $1 | openssl pkcs7 -print_certs`

# Node certificate
echo "$ALL_CERTS" | awk '/subject.*CN=.*.com/,/END CERTIFICATE/' | tail -n +3 > $2.crt

# Intermediate certificate
echo "$ALL_CERTS" | awk '/subject.*CN=DC1IntermediateCA01/,/END CERTIFICATE/' | tail -n +3 > intermediate.crt

# Root certificate
echo "$ALL_CERTS" | awk '/subject.*CN=DC1RootCA01/,/END CERTIFICATE/' | tail -n +3 > rootca.crt

# Form public cert chain (without bag attributes)
cat intermediate.crt rootca.crt > trustca.crt

# Form node cert chain (without bag attributes)
cat $2.crt trustca.crt > $2.chain.crt

# Import node key and node cert chain into the keystore file (of PKCS12 type)
openssl pkcs12 -export -name $2 \
      -in $2.chain.crt -inkey $2.key \
      -out $2.keystore.pkcs12 \
      -password pass:casspass20

# Import public cert chain into the truststore (of PKCS12 type)
keytool -delete -import -noprompt -alias trustca \
   -storetype PKCS12 \
   -file trustca.crt \
   -keystore truststore.pkcs12 \
   -storepass casspass20