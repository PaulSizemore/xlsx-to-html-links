# _generate_site.py
# 
# 
# 
# print('--------------------------------------------')
import os

file_dir = '/Users/paulb.sizemore/OneDrive/_github/data_csv-to-html-links/'

folder_list = [ name for name in os.listdir(file_dir) if os.path.isdir(os.path.join(file_dir, name)) ]

for i in folder_list:
    print('-------------------------------------------- generate index.html ')
    folder_path = file_dir + i

    print('Head: ' + i)
    print('Folder Path: ' + folder_path)
    htmlOut = '<!DOCTYPE HTML><html><head><style>body {font-family: Arial, Helvetica, sans-serif;} </style></head><body><h3></h3><h2>' + i + '</h2>'
    files = [ f for f in os.listdir(folder_path) if f.endswith(".html")]
    file_path = folder_path + '/index.htm'
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



        # text_out = htmlOut
        # with open(file_name, "w") as text_file:
        #     print(text_out, file=text_file)
    else: 
        print('NO FILES FOUND IN FOLDER')
        htmlOut = ''
    if len(htmlOut) > 1: 
        text_out = htmlOut
        with open(file_path, "w") as text_file:
            print(text_out, file=text_file)   

