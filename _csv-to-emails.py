# dev-csv-to-html.py
#
#
# Issues: select all, select none, open selected
# deselect certain domains
import time
import csv
import os
import pandas as pd
import datetime
import validators


#########################################
# list of URL's that are not included in the final output
urlCheckList = ['googleapis','public-api.wordpress','stats.wp.com','gstatic','@gmail.com','doubleclick.net','ads-api.twitter.com','.js','.svg','.css','plus.google.com','.jpg','.png']

file_dir = '/Users/paulb.sizemore/OneDrive/_github/data_csv-to-html-links/'

files = [  f for f in os.listdir(file_dir)  if f.endswith(".csv")]
log_text = ''

for i in files:
    print('-----------------------------------------------')
    print(i)
    #print('-----------------------------------------------')
    file_name = file_dir + i.replace(".csv","") + ".html"
    urlList = []


    try:
        df = pd.read_csv(file_dir + i)
        df = df.drop_duplicates()

        for name, values in df.iteritems():
            #print(name)
            for index, row in df.iterrows():
                testText = str(values[index])
                #################################################
                # Testing to see if URL was returned 
                if validators.url(testText):
                    # print('URL TO TEST:' + testText)
                    testCheckList = 0
                    ##############################################
                    # Testing to see if URL has a non-user string 
                    for k in urlCheckList:
                        # print(k)
                        if k in testText:
                            testCheckList = 1
                            # print(testCheckList)
                        else:
                            testCheckList = testCheckList
                            # print(testCheckList)

                    if testCheckList == 0: urlList.append(testText)

        urlList = list(dict.fromkeys(urlList))
        #urlList = urlList.sort()

        if len(urlList) > 1:
            htmlOut = '<!DOCTYPE HTML><html><head><style>body {font-family: Arial, Helvetica, sans-serif;} </style></head><body><h3><a href="#" onclick="yourlink()">Open All Links in</a></h3><h2>' + i + '</h2>'
            urlCounter = 0
            for j in urlList:
                urlCounter = urlCounter + 1
                htmlOut = htmlOut + '<span style="font-size:10px;">(' + str(urlCounter) + ')</span> <a href="' + j + '" target="_new" style="font-size:12px;" >' + j + '</a><BR>\n'
            htmlOut = htmlOut + '<script>function yourlink() {var locs = '
            htmlOut = htmlOut + str(urlList)
            htmlOut = htmlOut + ' \nfor (let i = 0; i < locs.length; i++) { window.open(locs[i])} };</script></body></html>	'

            text_out = htmlOut
            with open(file_name, "w") as text_file:
                print(text_out, file=text_file)
        else: log_text = log_text + 'No rows returned: ' + file_name + '\n'
    except:
        log_text = log_text + 'Error: ' + file_name + '\n'

file_name = file_dir + '_error.log'
with open(file_name, "w") as text_file:
    print(log_text, file=text_file)




