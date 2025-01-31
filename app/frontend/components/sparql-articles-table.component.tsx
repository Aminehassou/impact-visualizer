import React from "react";
import { convertSPARQLArticlesToCSV } from "../utils/search-utils";
import { SPARQLResponse } from "../types/search-tool.type";
import CSVButton from "./CSV-button.component";

export default function SparqlArticlesTable({
  articles,
  filename,
}: {
  articles: SPARQLResponse["results"]["bindings"];
  filename: string;
}) {
  return (
    <>
      <table className="articles-table">
        <thead>
          <tr>
            <th>
              Article
              <CSVButton
                articles={articles}
                csvConvert={convertSPARQLArticlesToCSV}
                filename={filename}
              />
            </th>
          </tr>
        </thead>
        <tbody>
          {articles.map((item, index) => (
            <tr key={index}>
              <td>
                {item.article ? (
                  <a href={item.article.value}>{item.personLabel.value}</a>
                ) : (
                  <a href={item.person.value}>{item.personLabel.value}</a>
                )}{" "}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </>
  );
}
