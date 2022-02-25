# _xlsx_collect_files.py
# 
#
# 
# 
import os
import re
import shutil






file_dir = '/Users/paulb.sizemore/OneDrive/_github/data_csv-to-html-links/'

files = [
    f for f in os.listdir(file_dir)
    if f.endswith(".xlsx")]

#########################################
# Loop the Excel Files
for i in files:
    #print('-----------------------------------------------')
    print('Excel file found: ' + i)
    #print('-----------------------------------------------')
    siteName = i.replace(".xlsx","")
    directory = file_dir + siteName

    if not os.path.exists(directory):
        os.makedirs(directory)

    for k in os.listdir(file_dir):
        if k.startswith(siteName):
            file = file_dir + k
            to_file = file_dir + siteName + '/' + k
            if siteName != k:
                print('Moving file: ' + file)
                #print(file)
                #print(to_file)
                try:
                    shutil.move(file, to_file)
                except Exception as e:
                    print("Error: " + e.__str__())



print('-----------------------------------------------')
print('-----------------------------------------------')
print('-----------------------------------------------')
print('GENERATING INDEX.HTML FILES')
print('-----------------------------------------------')
print('-----------------------------------------------')
print('-----------------------------------------------')




#############################################################
# Generate the Index File that links to all the HTML files 

file_dir = '/Users/paulb.sizemore/OneDrive/_github/data_csv-to-html-links/'

folder_list = [ name for name in os.listdir(file_dir) if os.path.isdir(os.path.join(file_dir, name)) ]

for i in folder_list:
    print('-------------------------------------------- generate index.html ')
    folder_path = file_dir + i

    print('Head: ' + i)
    print('Folder Path: ' + folder_path)
    htmlOut = '<!DOCTYPE HTML><html><head><style>body {font-family: Arial, Helvetica, sans-serif;} </style></head><body><h3></h3><h2>' + i + '</h2>'
    files = [ f for f in os.listdir(folder_path) if f.endswith(".html")]
    file_path = folder_path + '/index.html'
    print('Index file to create: ' + file_path)

    if len(files) > 0:
        for k in files: 

            title = k.replace('.html','')
            title = title.replace(i,'')
            title = title.replace('_',' ')
            print('Title: ' + title)
            print('Linked File: ' + k)

            htmlOut = htmlOut + '<p><a href="./' + k +  '">' + title + '</a></p>'


        htmlOut = htmlOut + '</body></html>	'

    else: 
        print('NO FILES FOUND IN FOLDER')
        htmlOut = ''
    if len(htmlOut) > 1: 
        text_out = htmlOut
        with open(file_path, "w") as text_file:
            print(text_out, file=text_file)   

